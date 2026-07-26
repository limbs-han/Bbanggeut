pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        disableConcurrentBuilds(abortPrevious: true)
        skipDefaultCheckout(true)
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
    }

    environment {
        CI = 'true'
        PIP_DISABLE_PIP_VERSION_CHECK = '1'
    }

    stages {
        stage('Domain CI') {
            parallel {
                stage('Backend') {
                    when {
                        beforeAgent true
                        anyOf {
                            branch 'master'
                            branch 'develop'
                            branch 'develop/backend'
                            branch pattern: 'feat/backend/**', comparator: 'GLOB'
                            branch 'feat/jenkins-pipeline'
                        }
                    }
                    agent {
                        label 'backend'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        dir('backend/server') {
                            sh 'chmod +x gradlew'
                            sh './gradlew --no-daemon clean test bootJar'
                        }
                        junit allowEmptyResults: false,
                            testResults: 'backend/server/build/test-results/test/TEST-*.xml'
                        archiveArtifacts artifacts: 'backend/server/build/libs/server-*.jar',
                            fingerprint: true
                    }
                    post {
                        cleanup {
                            cleanWs(deleteDirs: true, disableDeferredWipeout: true)
                        }
                    }
                }

                stage('Frontend') {
                    when {
                        beforeAgent true
                        anyOf {
                            branch 'master'
                            branch 'develop'
                            branch 'develop/frontend'
                            branch pattern: 'feat/frontend/**', comparator: 'GLOB'
                            branch 'feat/jenkins-pipeline'
                        }
                    }
                    agent {
                        label 'frontend'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        dir('frontend') {
                            sh 'flutter pub get'
                            sh 'flutter analyze'
                            sh 'flutter test --reporter expanded'
                        }
                    }
                    post {
                        cleanup {
                            cleanWs(deleteDirs: true, disableDeferredWipeout: true)
                        }
                    }
                }

                stage('IoT Device Agent') {
                    when {
                        beforeAgent true
                        anyOf {
                            branch 'master'
                            branch 'develop'
                            branch 'develop/iot'
                            branch pattern: 'feat/iot/**', comparator: 'GLOB'
                            branch 'feat/jenkins-pipeline'
                        }
                    }
                    agent {
                        label 'iot'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        dir('ai/device_agent') {
                            sh 'python3 -m venv .venv-ci'
                            sh '.venv-ci/bin/python -m pip install -r requirements.txt'
                            sh '.venv-ci/bin/python -m unittest discover -s tests -v'
                        }
                    }
                    post {
                        cleanup {
                            cleanWs(deleteDirs: true, disableDeferredWipeout: true)
                        }
                    }
                }

                stage('AI Logic') {
                    when {
                        beforeAgent true
                        anyOf {
                            branch 'master'
                            branch 'develop'
                            branch 'develop/ai'
                            branch pattern: 'feat/ai/**', comparator: 'GLOB'
                            branch 'feat/jenkins-pipeline'
                        }
                    }
                    agent {
                        label 'ai'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        dir('ai/yolo') {
                            sh 'python3 -m unittest -v test_event_fusion.py test_laughter_clip_uploader.py'
                            sh 'python3 -m py_compile *.py'
                            sh 'bash -n run_ai_stack.sh run_edge_ai_mvp.sh'
                        }
                    }
                    post {
                        cleanup {
                            cleanWs(deleteDirs: true, disableDeferredWipeout: true)
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            echo "${env.BRANCH_NAME} 브랜치 CI가 통과했습니다: ${env.GIT_COMMIT}"
        }
        failure {
            echo "${env.BRANCH_NAME} 브랜치 CI가 실패했습니다. 실패한 영역 단계를 확인하세요."
        }
    }
}
