pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        copyArtifactPermission('/Production/S15P11E201-backend-deploy')
        disableConcurrentBuilds(abortPrevious: true)
        gitLabConnection('s15p11e201-gitlab-api')
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
                            branch 'develop/backend'
                            branch pattern: 'feat/backend/**', comparator: 'GLOB'
                            branch pattern: 'feat/jenkins-*', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'backend'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        sh 'git rev-parse HEAD > ci/jenkins/commit.txt'
                        gitlabCommitStatus(name: 'ci/backend') {
                            sh 'bash ci/jenkins/scripts/test-deploy-jar-validation.sh'
                            sh 'bash ci/jenkins/scripts/run-backend-ci.sh'
                            sh 'bash ci/jenkins/server/deploy/wj-deploy-backend --validate-only backend/server/build/libs/server-*.jar'
                            junit allowEmptyResults: false,
                                testResults: 'backend/server/build/test-results/test/TEST-*.xml'
                            archiveArtifacts artifacts: 'backend/server/build/libs/server-*.jar,ci/jenkins/commit.txt',
                                fingerprint: true
                        }
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
                            branch 'develop/frontend'
                            branch pattern: 'feat/frontend/**', comparator: 'GLOB'
                            branch pattern: 'feat/jenkins-*', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'frontend'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        gitlabCommitStatus(name: 'ci/frontend') {
                            dir('frontend') {
                                sh 'flutter pub get'
                                sh 'flutter analyze'
                                sh 'flutter test --reporter expanded'
                            }
                        }
                    }
                    post {
                        cleanup {
                            cleanWs(deleteDirs: true, disableDeferredWipeout: true)
                        }
                    }
                }

                stage('Device (IoT + AI)') {
                    when {
                        beforeAgent true
                        anyOf {
                            branch 'master'
                            branch 'develop/device'
                            branch pattern: 'feat/device/**', comparator: 'GLOB'
                            branch pattern: 'feat/jenkins-*', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'device'
                    }
                    steps {
                        deleteDir()
                        checkout scm
                        gitlabCommitStatus(name: 'ci/device') {
                            dir('ai/device_agent') {
                                sh 'python3 -m venv .venv-ci'
                                sh '.venv-ci/bin/python -m pip install -r requirements.txt'
                                sh '.venv-ci/bin/python -m unittest discover -s tests -v'
                            }
                            dir('ai/yolo') {
                                sh 'python3 -m unittest -v test_event_fusion.py test_laughter_clip_uploader.py'
                                sh 'python3 -m py_compile *.py'
                                sh 'bash -n run_ai_stack.sh run_edge_ai_mvp.sh'
                            }
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
