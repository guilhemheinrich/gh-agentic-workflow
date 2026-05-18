# Official image bundles SonarScanner CLI and the Java runtime required by the scanner.
FROM sonarsource/sonar-scanner-cli:latest

USER root
COPY run-sonar-scanner.sh /usr/local/bin/run-sonar-scanner
RUN chmod +x /usr/local/bin/run-sonar-scanner

WORKDIR /workspace
ENTRYPOINT ["run-sonar-scanner"]
