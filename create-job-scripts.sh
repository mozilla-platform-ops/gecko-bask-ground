#!/bin/bash

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

indexed_builds=( gecko.v2.mozilla-central.latest.firefox.win64-debug gecko.v2.mozilla-central.latest.firefox.win64-asan-opt gecko.v2.mozilla-central.latest.firefox.win64-ccov-opt )
worker_types=( t-win10-64 )


rm ${script_dir}/jobs/*.yml
mkdir -p ${script_dir}/jobs
for indexed_build in ${indexed_builds[@]}; do
  curl -sL https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/${indexed_build} --output indexed-build-task-${indexed_build}.json
  build_task_id=$(jq -r '.taskId' indexed-build-task-${indexed_build}.json)
  curl -sL https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/${build_task_id} --output build-task-${build_task_id}.json
  build_task_group_id=$(jq -r '.taskGroupId' build-task-${build_task_id}.json)
  echo "- build task id: ${build_task_id}, in task group: ${build_task_group_id}, determined for indexed build: ${indexed_build}"

  i="1"
  continuation_token=""
  while [ $i -lt 2 ] || [ "${continuation_token}" != "null" ]; do
    if [ $i -lt 2 ]; then
      curl -sL "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list" --output indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json
    else
      curl -sL "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list?continuationToken=${continuation_token}" --output indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json
    fi
    continuation_token=$(jq -r '.continuationToken' indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json)
    i=$[$i+1]
  done
  jq -s '[.[].tasks]|flatten' indexed-build-task-group-${indexed_build}-*.json > indexed-build-task-group-${indexed_build}.json
  #curl -sL https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list --output indexed-build-task-group-${indexed_build}.json

  for worker_type in ${worker_types[@]}; do
    jq --arg workerType ${worker_type} --arg buildTaskId ${build_task_id} '[ .[] | select(.status.workerType == $workerType and (.task.dependencies as $d | $buildTaskId | IN($d[]))) ]' indexed-build-task-group-${indexed_build}.json > tasks-${worker_type}.json
    echo "  - $(jq length tasks-${worker_type}.json) tasks found for worker type: ${worker_type}"

    for task_base64 in $(jq -r '.[] | @base64' tasks-${worker_type}.json); do
      _jq() {
        echo ${task_base64} | base64 --decode | jq -r ${1}
      }
      task_name=$(_jq '.task.metadata.name')
      test_suite=$(_jq '.task.extra.suite')
      commit_sha=$(_jq '.task.payload.env.GECKO_HEAD_REV')
      command_0=$(_jq '.task.payload.command[0]')
      #mozharness_artifact_task_id=$(_jq '.task.payload.mounts[] | select(.format == "zip" and .directory == "mozharness") | .content.taskId')


      #job=(${task_name/\// })
      if [ ! -f ${script_dir}/jobs/${test_suite}.yml ]; then
        echo "---" > ${script_dir}/jobs/${test_suite}.yml
        echo "name: ${test_suite}" >> ${script_dir}/jobs/${test_suite}.yml
        echo "on:" >> ${script_dir}/jobs/${test_suite}.yml
        echo "  push:" >> ${script_dir}/jobs/${test_suite}.yml
        echo "    branches:" >> ${script_dir}/jobs/${test_suite}.yml
        echo "      - main:" >> ${script_dir}/jobs/${test_suite}.yml
        echo "jobs:" >> ${script_dir}/jobs/${test_suite}.yml
        echo "created: ${script_dir}/jobs/${test_suite}.yml"
      else
        echo "detected: ${script_dir}/jobs/${test_suite}.yml"
      fi
      echo "  ${task_name}:" >> ${script_dir}/jobs/${test_suite}.yml
      echo "    runs-on: windows-2019" >> ${script_dir}/jobs/${test_suite}.yml
      echo "    steps:" >> ${script_dir}/jobs/${test_suite}.yml
      echo "      - uses: actions/checkout@v2" >> ${script_dir}/jobs/${test_suite}.yml
      echo "      - name: mounts" >> ${script_dir}/jobs/${test_suite}.yml
      echo "        run: |" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          curl -L https://hg.mozilla.org/try/raw-file/${commit_sha}/taskcluster/scripts/misc/fetch-content --output fetch-content" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          curl -L https://hg.mozilla.org/try/raw-file/${commit_sha}/taskcluster/scripts/run-task --output run-task" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          curl -L https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/${build_task_id}/artifacts/public/build/mozharness.zip --output mozharness.zip" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          7z x -omozharness mozharness.zip" >> ${script_dir}/jobs/${test_suite}.yml
      echo "      - name: python deps" >> ${script_dir}/jobs/${test_suite}.yml
      echo "        run: |" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          python -m pip install --upgrade zstandard" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          python -m pip install --upgrade certifi" >> ${script_dir}/jobs/${test_suite}.yml
      echo "      - name: task" >> ${script_dir}/jobs/${test_suite}.yml
      echo "        env:" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          TASKCLUSTER_ROOT_URL: https://firefox-ci-tc.services.mozilla.com" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          PYTHON: C:\hostedtoolcache\windows\Python\3.7.9\x64\python.exe" >> ${script_dir}/jobs/${test_suite}.yml
      echo "        run: |" >> ${script_dir}/jobs/${test_suite}.yml
      echo "          ${command_0/C:\/mozilla-build\/python3\/python3.exe run-task -- c:\\\\mozilla-build\\\\python3\\\\python3.exe/python run-task -- python}" >> ${script_dir}/jobs/${test_suite}.yml
    done
  done
done
