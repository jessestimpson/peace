(ns jepsen.peace
  "A Jepsen test for peace. See jepsen/README.md.

  The system under test is a key-value store: one peace server per node,
  with the peace_kv machine, behind the HTTP interface of peace_kv_http.

  The workload is the compare-and-swap register workload of the Jepsen
  tutorial, on independent keys. The checker is Knossos, with a
  compare-and-swap register as the model."
  (:require [clojure.string :as str]
            [clojure.tools.logging :refer [info warn]]
            [clj-http.client :as http]
            [jepsen [checker :as checker]
                    [cli :as cli]
                    [client :as client]
                    [control :as c]
                    [db :as db]
                    [generator :as gen]
                    [independent :as independent]
                    [nemesis :as nemesis]
                    [tests :as tests]
                    [util :as util]]
            [jepsen.checker.timeline :as timeline]
            [jepsen.control.util :as cu]
            [jepsen.nemesis.combined :as nc]
            [knossos.model :as model]))

(def dir     "/opt/peace")
(def logfile (str dir "/peace.log"))
(def pidfile (str dir "/peace.pid"))
(def tarball "/jepsen/peace.tar.gz")
(def port    8080)

(defn node-name
  "The Erlang node name of the peace node on a Jepsen node."
  [node]
  (str "peace@" node))

(defn members
  "The value of the members argument of peace_kv_node: every node of the test."
  [test]
  (str/join "," (map node-name (:nodes test))))

(defn quorum
  "The value of the quorum argument of peace_kv_node. The option
  \"grid:R\" arranges the nodes of the test in rows of R nodes."
  [test]
  (let [q (:quorum test)]
    (cond
      (re-matches #"grid:\d+" q)
      (->> (:nodes test)
           (map node-name)
           (partition-all (parse-long (subs q 5)))
           (map #(str/join "+" %))
           (str/join "/")
           (str "grid:"))

      ; "weighted:2+1+1" gives the weights of the nodes, in order.
      (str/starts-with? q "weighted:")
      (->> (map (fn [node w] (str (node-name node) "=" w))
                (:nodes test)
                (str/split (subs q 9) #"\+"))
           (str/join "+")
           (str "weighted:"))

      :else q)))

(defn clock-args
  "The clock arguments of peace_kv_node. With --clock-rate-spread P, every
  start of a node picks a clock rate between 1 - P/200 and 1 + P/200."
  [test]
  (let [spread (:clock-rate-spread test)
        lease  (:read-lease-ms test)]
    (concat
      (when lease
        [:-peace_kv_node "read_lease_ms" (str lease)])
      (when (pos? spread)
        [:-peace_kv_node "clock_rate"
         (str (+ 1000 (- (rand-int (inc (* 10 spread))) (* 5 spread))) "/1000")]))))

(defn wall-clock-args
  "The command prefix that changes the wall clock of the node. With
  --wall-clock-skew, every start of a node picks an offset between -1 hour
  and +1 hour and a rate between 0.5 and 2. libfaketime changes the wall
  clock of the Erlang emulator. It does not change the monotonic clock."
  [test]
  (when (:wall-clock-skew test)
    ["/usr/bin/faketime" "-f"
     (format "%+ds x%.2f" (- (rand-int 7201) 3600) (+ 0.5 (* 1.5 (rand))))]))

(defn erl-args
  "The arguments of erl that do not depend on the clock options."
  [test node]
  [:-noinput
      :-sname (node-name node)
      :-setcookie "jepsen"
      :-pa (str dir "/ebin") (str dir "/bench") (str dir "/node")
      :-peace "data_dir" (str "\"" dir "/data\"")
      :-peace_kv_node "members" (members test)
      :-peace_kv_node "quorum" (quorum test)
      :-peace_kv_node "reads" (if (:stale-reads test) "stale" "consistent")
      :-peace_kv_node "port" (str port)
      :-s "peace_kv_node"])

(defn start-node!
  "Starts the Erlang node. The node recovers its state from /opt/peace/data."
  [test node]
  (c/su
    (apply cu/start-daemon!
      {:logfile logfile
       :pidfile pidfile
       :chdir   dir}
      (concat
        (wall-clock-args test)
        ["/usr/local/bin/erl"]
        (clock-args test)
        (erl-args test node)))))

(defn signal!
  "Sends a signal to the Erlang emulator on the current node. pkill -x
  matches the process name, so it does not match the shell that runs it."
  [sig]
  (c/su (c/exec :bash :-c (str "pkill -" sig " -x beam.smp || true"))))

(defn kill-node!
  "Kills the Erlang node without a shutdown."
  [test node]
  (signal! "KILL")
  (c/su (c/exec :rm :-f pidfile)))

(defn status
  "The answer of GET /status on a node, or nil."
  [node]
  (try
    (let [r (http/get (str "http://" node ":" port "/status")
                      {:throw-exceptions false
                       :socket-timeout 2000
                       :connection-timeout 2000})]
      (when (= 200 (:status r)) (:body r)))
    (catch Exception _ nil)))

(defn db
  "The peace key-value node."
  []
  (reify
    db/DB
    (setup! [_ test node]
      (info node "installing peace")
      (c/su
        (c/exec :rm :-rf dir)
        (c/exec :mkdir :-p dir)
        (c/upload tarball "/tmp/peace.tar.gz")
        (c/exec :tar :xzf "/tmp/peace.tar.gz" :-C dir))
      (start-node! test node)
      ; The node answers /status when its HTTP server is up. A leader is
      ; elected within two election timeouts after a quorum is up.
      (util/await-fn (fn [] (or (status node) (throw (RuntimeException. "not up"))))
                     {:timeout 60000 :log-message "waiting for peace"})
      (Thread/sleep 5000))

    (teardown! [_ test node]
      (info node "removing peace")
      (kill-node! test node)
      (c/su (c/exec :rm :-rf dir)))

    db/Process
    (start! [_ test node] (start-node! test node))
    (kill!  [_ test node] (kill-node! test node))

    db/Pause
    (pause!  [_ test node] (signal! "STOP"))
    (resume! [_ test node] (signal! "CONT"))

    db/LogFiles
    (log-files [_ test node] [logfile])))

; The HTTP client must not repeat a request. The default retry handler
; repeats a PUT after an I/O error, and a repeated compare-and-set can take
; effect twice.
(def http-opts
  {:throw-exceptions   false
   :socket-timeout     10000
   :connection-timeout 5000
   :retry-handler      (fn [_ex _count _context] false)})

(defn indeterminate
  "The result of an operation whose outcome is unknown. A read changes
  nothing, so a read with an unknown outcome is a failure."
  [op error]
  (assoc op :type (if (= :read (:f op)) :fail :info) :error error))

(defrecord Client [node]
  client/Client
  (open! [this test node] (assoc this :node node))
  (setup! [this test])

  (invoke! [this test op]
    (let [[k v] (:value op)
          url   (str "http://" node ":" port "/kv/" k)]
      (try
        (let [r (case (:f op)
                  :read  (http/get url http-opts)
                  :write (http/put url (assoc http-opts :query-params {"value" v}))
                  :cas   (let [[old new] v]
                           (http/put url (assoc http-opts :query-params
                                                {"value" new "expected" old}))))]
          (case (long (:status r))
            200 (assoc op :type :ok
                       :value (independent/tuple k (parse-long (:body r))))
            204 (assoc op :type :ok)
            ; The key has no value. A read returns nil. A compare-and-swap
            ; did not happen.
            404 (if (= :read (:f op))
                  (assoc op :type :ok :value (independent/tuple k nil))
                  (assoc op :type :fail :error :not-found))
            409 (assoc op :type :fail :error :mismatch)
            ; The request was not submitted.
            503 (assoc op :type :fail :error [:not-submitted (:body r)])
            504 (indeterminate op [:unknown (:body r)])
            (indeterminate op [:status (:status r)])))
        ; The connection was refused, so the request was not sent.
        (catch java.net.ConnectException e
          (assoc op :type :fail :error :connection-refused))
        (catch Exception e
          (indeterminate op [:exception (.getName (class e))])))))

  (teardown! [this test])
  (close! [this test]))

(defn random-quorum
  "A random quorum system for the given nodes, in the syntax of the quorum
  argument of peace_kv_node."
  [nodes]
  (let [n     (count nodes)
        names (map node-name nodes)]
    (case (rand-nth (if (= 4 n)
                      [:majority :counting :weighted :grid]
                      [:majority :counting :weighted]))
      :majority "majority"
      ; Any Q2 from 2 to N - 1, and the smallest Q1 that intersects it. The
      ; sizes 1 and N are left out, because a quorum of N members is not
      ; available while any member is down, and the test would then
      ; perform few operations.
      :counting (let [q2 (+ 2 (rand-int (- n 2)))]
                  (str "counting:" (- (inc n) q2) ":" q2))
      :weighted (str "weighted:"
                     (str/join "+" (map #(str % "=" (inc (rand-int 2))) names)))
      :grid     (str "grid:"
                     (str/join "/" (map #(str/join "+" %) (partition 2 names)))))))

(defn members-nemesis
  "A nemesis that changes the members of the cluster. A :members operation
  asks a random node to change the members to a random set of 3 to 5 nodes
  with majority quorums. A :quorums operation does the same and also picks a
  random quorum system."
  []
  (reify nemesis/Nemesis
    (setup! [this test] this)
    (invoke! [this test op]
      (let [nodes  (:nodes test)
            target (take (+ 3 (rand-int (- (count nodes) 2))) (shuffle nodes))
            quorum (if (= :quorums (:f op)) (random-quorum target) "majority")
            via    (rand-nth nodes)
            value  {:via via :members (sort target) :quorum quorum}]
        (try
          (let [r (http/post (str "http://" via ":" port "/members")
                             (assoc http-opts :query-params
                                    {"nodes"  (str/join "," (map node-name target))
                                     "quorum" quorum}))]
            (assoc op :value (assoc value :status (:status r) :body (:body r))))
          (catch Exception e
            (assoc op :value (assoc value :error (.getName (class e))))))))
    (teardown! [this test])
    nemesis/Reflection
    (fs [this] #{:members :quorums})))

(defn r   [_ _] {:type :invoke :f :read  :value nil})
(defn w   [_ _] {:type :invoke :f :write :value (rand-int 5)})
(defn cas [_ _] {:type :invoke :f :cas   :value [(rand-int 5) (rand-int 5)]})

(def all-faults #{:partition :kill :pause :members :quorums})

(defn parse-faults
  [s]
  (if (= s "none")
    #{}
    (set (map keyword (str/split s #",")))))

(defn stats-checker
  "The statistics of the run. checker/stats reports a run as invalid if one
  kind of operation never succeeds. That happens in a short run in which
  the nodes are down most of the time, and it is not a safety violation.
  This checker reports the same statistics and is always valid."
  []
  (reify checker/Checker
    (check [_ test history opts]
      (assoc (checker/check (checker/stats) test history opts) :valid? true))))

(defn peace-test
  "Builds the test map from the command line options."
  [opts]
  (let [db       (db)
        faults   (:faults opts)
        interval (:nemesis-interval opts)
        ; The test composes the partition package and the process package
        ; only. nc/nemesis-package also sets up the file corruption and
        ; clock nemeses, which download programs to the nodes.
        pkg-opts {:db        db
                  :nodes     (:nodes opts)
                  :faults    (disj faults :members :quorums)
                  :interval  interval
                  :partition {:targets [:one :majority :majorities-ring]}
                  :kill      {:targets [:one :majority :all]}
                  :pause     {:targets [:one :majority]}}
        pkg      (nc/compose-packages [(nc/partition-package pkg-opts)
                                       (nc/db-package pkg-opts)])
        member-fs (filter faults [:members :quorums])
        members?  (seq member-fs)
        nemesis  (if members?
                   (nemesis/compose {(nemesis/fs (:nemesis pkg)) (:nemesis pkg)
                                     #{:members :quorums} (members-nemesis)})
                   (:nemesis pkg))
        members-gen (when members?
                      (->> (fn [_ _] {:type :info :f (rand-nth member-fs)})
                           (gen/stagger (* 2 interval))))
        nemesis-gen (gen/any (:generator pkg) members-gen)]
    (merge tests/noop-test
           opts
           {:name      (str "peace " (:quorum opts) " "
                            (if (empty? faults) "none" (str/join "," (map name (sort faults))))
                            (when (:read-lease-ms opts) (str " lease " (:read-lease-ms opts)))
                            (when (pos? (:clock-rate-spread opts))
                              (str " rates " (:clock-rate-spread opts)))
                            (when (:wall-clock-skew opts) " wall-clock"))
            :os        jepsen.os/noop
            :db        db
            :client    (Client. nil)
            :nemesis   nemesis
            :checker   (checker/compose
                         {:perf       (checker/perf {:nemeses (:perf pkg)})
                          :stats      (stats-checker)
                          :exceptions (checker/unhandled-exceptions)
                          :workload   (independent/checker
                                        (checker/compose
                                          {:linear   (checker/linearizable
                                                       {:model     (model/cas-register)
                                                        :algorithm :linear})
                                           :timeline (timeline/html)}))})
            :generator (gen/phases
                         (->> (independent/concurrent-generator
                                (:threads-per-key opts)
                                (range)
                                (fn [k]
                                  (->> (gen/mix [r w cas])
                                       (gen/stagger (/ (:rate opts)))
                                       (gen/limit (:ops-per-key opts)))))
                              (gen/nemesis nemesis-gen)
                              (gen/time-limit (:time-limit opts)))
                         ; Heal the network and restart every node, so that
                         ; the logs of every node are complete.
                         (gen/nemesis (:final-generator pkg))
                         (gen/sleep 5))})))

(def cli-opts
  [[nil "--faults FAULTS" "A comma-separated list of partition, kill, pause, members and quorums, or none."
    :default  #{:partition :kill :pause}
    :parse-fn parse-faults
    :validate [#(every? all-faults %) "must be partition, kill, pause, members, quorums or none"]]
   [nil "--quorum SPEC" "The quorum system: majority, counting:Q1:Q2, grid:R for rows of R nodes, or weighted:W+W+... for the weights of the nodes."
    :default  "majority"
    :validate [#(re-matches #"majority|counting:\d+:\d+|grid:\d+|weighted:\d+(\+\d+)*" %)
               "must be majority, counting:Q1:Q2, grid:R or weighted:W+W+..."]]
   [nil "--read-lease-ms MS" "The read_lease_ms option of the cluster. Read leases are off by default."
    :parse-fn parse-long]
   [nil "--clock-rate-spread PERCENT" "The width of the range of the clock rates of the nodes, in percent."
    :default  0
    :parse-fn parse-long]
   [nil "--wall-clock-skew" "Every node starts with a random wall clock offset and rate."
    :default false]
   [nil "--stale-reads" "Nodes answer reads from local state. The test is expected to fail."
    :default false]
   [nil "--nemesis-interval SECONDS" "The mean time between nemesis operations."
    :default  10
    :parse-fn parse-long]
   [nil "--rate HZ" "The mean number of operations per second, per key."
    :default  10
    :parse-fn read-string]
   [nil "--ops-per-key COUNT" "The number of operations on each key."
    :default  200
    :parse-fn parse-long]
   [nil "--threads-per-key COUNT" "The number of client threads that share a key."
    :default  5
    :parse-fn parse-long]])

(defn -main
  [& args]
  (cli/run! (merge (cli/single-test-cmd {:test-fn  peace-test
                                         :opt-spec cli-opts})
                   (cli/serve-cmd))
            args))
