pipeline {
    agent { label 'linux-worker' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    stages {
        stage('Install Test Dependencies') {
            steps {
                // Idempotent. Only touches package install - update.sh itself is
                // never run against real Proxmox/pct in this pipeline, so nothing
                // here needs broader privileges than installing two packages.
                sh 'sudo apt-get update && sudo apt-get install -y shellcheck bats'
            }
        }

        stage('Lint') {
            steps {
                sh '''
                    bash -n update.sh
                    bash -n install.sh
                    shellcheck update.sh install.sh
                '''
            }
        }

        stage('Test') {
            steps {
                // Runs entirely against tests/mocks/pct and tests/mocks/ping -
                // no real Proxmox host, containers, or network access involved.
                sh 'bats tests/'
            }
        }
    }

    post {
        failure {
            echo 'Build failed - check the Lint or Test stage output above for the specific error.'
        }
    }
}
