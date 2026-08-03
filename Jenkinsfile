pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        copyArtifactPermission('/Production/S15P11E201-backend-deploy')
        disableConcurrentBuilds(abortPrevious: true)
        gitLabConnection('s15p11e201-gitlab-api')
        parallelsAlwaysFailFast()
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
                            branch pattern: 'feat/backend/**', comparator: 'GLOB'
                            branch pattern: 'fix/backend/**', comparator: 'GLOB'
                            branch pattern: 'feat/jenkins-*', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'backend'
                    }
                    steps {
                        gitlabCommitStatus(name: 'ci/backend') {
                            deleteDir()
                            checkout scm
                            sh 'git rev-parse HEAD > ci/jenkins/commit.txt'
                            sh 'bash ci/jenkins/scripts/test-backend-deploy-contract.sh'
                            sh 'bash ci/jenkins/scripts/test-deploy-jar-validation.sh'
                            sh 'bash ci/jenkins/scripts/run-backend-ci.sh'
                            sh 'bash ci/jenkins/scripts/package-backend-deploy.sh backend-deploy.tar.gz'
                            sh 'bash ci/jenkins/server/deploy/wj-deploy-backend --validate-only backend/server/build/libs/server-*.jar'
                            junit allowEmptyResults: false,
                                testResults: 'backend/server/build/test-results/test/TEST-*.xml'
                            archiveArtifacts artifacts: 'backend/server/build/libs/server-*.jar,backend-deploy.tar.gz,ci/jenkins/commit.txt',
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
                            branch 'develop'
                            branch pattern: 'feat/frontend/**', comparator: 'GLOB'
                            branch pattern: 'fix/frontend/**', comparator: 'GLOB'
                            branch pattern: 'feat/jenkins-*', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'frontend'
                    }
                    steps {
                        gitlabCommitStatus(name: 'ci/frontend') {
                            deleteDir()
                            checkout scm
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

                stage('API Contract') {
                    when {
                        beforeAgent true
                        anyOf {
                            branch 'master'
                            branch 'develop'
                            branch pattern: 'feat/**', comparator: 'GLOB'
                            branch pattern: 'fix/**', comparator: 'GLOB'
                            branch pattern: 'docs/**', comparator: 'GLOB'
                            branch pattern: 'chore/**', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'backend'
                    }
                    steps {
                        gitlabCommitStatus(name: 'ci/api-contract') {
                            deleteDir()
                            checkout scm
                            sh 'bash ci/jenkins/scripts/run-api-contract-ci.sh'
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
                            branch 'develop'
                            branch pattern: 'feat/device/**', comparator: 'GLOB'
                            branch pattern: 'fix/device/**', comparator: 'GLOB'
                            branch pattern: 'feat/jenkins-*', comparator: 'GLOB'
                        }
                    }
                    agent {
                        label 'device'
                    }
                    steps {
                        gitlabCommitStatus(name: 'ci/device') {
                            deleteDir()
                            checkout scm
                            dir('ai/device_agent') {
                                sh 'python3 -m venv .venv-ci'
                                sh '.venv-ci/bin/python -m pip install -r requirements.txt'
                                sh '.venv-ci/bin/python -m unittest discover -s tests -v'
                            }
                            dir('ai/yolo') {
                                sh 'python3 -m unittest -v test_event_fusion.py test_laughter_clip_uploader.py test_segment_clip_uploader.py test_edge_ai_recording_startup.py test_yolo_runtime_selector.py'
                                sh 'python3 -m py_compile *.py'
                                sh 'bash -n run_ai_stack.sh run_edge_ai_mvp.sh run_edge_ai_recording.sh'
                            }
                            dir('ai/yamnet') {
                                sh 'python3 -m unittest -v test_audio_event_detection.py test_audio_event_trigger.py'
                                sh 'python3 -m py_compile audio_event_detection.py audio_event_trigger.py yamnet_laughter_detect_jetson.py'
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
