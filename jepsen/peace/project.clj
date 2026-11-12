(defproject jepsen.peace "0.1.0"
  :description "A Jepsen test for peace"
  :license {:name "Apache-2.0"}
  :main jepsen.peace
  :jvm-opts ["-Xmx700m" "-Djava.awt.headless=true"]
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [jepsen "0.3.9"]
                 [clj-http "3.13.0"]])
