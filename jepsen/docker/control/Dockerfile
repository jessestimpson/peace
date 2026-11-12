# The control node of the Jepsen test: a JVM, Leiningen, an SSH client and
# the tools that the Jepsen checkers use to draw graphs.
FROM clojure:temurin-21-lein

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-client gnuplot-nox graphviz git curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /jepsen/peace
CMD ["sleep", "infinity"]
