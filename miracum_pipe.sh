#!/usr/bin/env bash

readonly DIR_SCRIPT=$(
  cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
  pwd -P
)

## load settings
# shellcheck source=common.cfg.sh
. "${DIR_SCRIPT}"/common.cfg.sh

readonly VALID_TASKS=("gd td vc cnv report td_gd_parallel vc_cnv_parallel")

function usage() {
  echo "usage: miracum_pipe.sh [-d dir] [-t task] [-f] [-h]"
  echo "  -t  task             specify task ${VALID_TASKS}"
  echo "  -f                   specify forced run, i.e. neglecting if a patient already was computed"
  echo "  -d  dir              specify directory in which the patient is located"
  echo "  -s                   computing sequentially; might be required if ressources are limited"
  echo "  -h                   show this help screen"
  exit 1
}


# setup relative_patient_dir dir_target
function setup() {
  local dir_patient="${1}"
  local dir_target="${2}"

  local dir_tmp="$(get_config_value common.dirTmp "${dir_patient}")/${dir_patient}"
  mkdir -p ${dir_tmp}

  local dir_log="${dir_target}/log"
  mkdir -p "${dir_log}"
}

# cleanup relative_patient_dir
function cleanup() {
  local dir_patient="${1}"
  local dir_tmp="$(get_config_value common.dirTmp "${dir_patient}")/${dir_patient}"
  rm -rf "${dir_tmp:?}"
}

# run_pipe relative_patient_dir dir_target
function run_pipe() {
  local dir_patient="${1}"
  local dir_target="${2}"

  local dir_log="${dir_target}/log"

  setup "${dir_patient}" "${dir_target}"

  # use parallel shell scripting
  ("${DIR_SCRIPT}"/make_alignment.sh -p -t td -d "${dir_patient}" &> ${dir_log}/td.log) &
  ("${DIR_SCRIPT}"/make_alignment.sh -p -t gd -d "${dir_patient}" &> ${dir_log}/gd.log) &
  wait

  # use parallel shell scripting
  ("${DIR_SCRIPT}"/make_vc.sh  -p -d "${dir_patient}" &> ${dir_log}/vc.log) &
  ("${DIR_SCRIPT}"/make_cnv.sh -p -d "${dir_patient}" &> ${dir_log}/cnv.log) &
  wait

  # create report based on the results of the processes above
  ("${DIR_SCRIPT}"/make_report.sh -d "${dir_patient}" &> ${dir_log}/report.log)

  cleanup "${dir_patient}"
}

# run_pipe_seq relative_patient_dir dir_target
function run_pipe_seq() {
  local dir_patient="${1}"
  local dir_target="${2}"

  local dir_log="${dir_target}/log"

  setup "${dir_patient}" "${dir_target}"

  ("${DIR_SCRIPT}"/make_alignment.sh -t td -d "${dir_patient}" &> ${dir_log}/td.log)
  ("${DIR_SCRIPT}"/make_alignment.sh -t gd -d "${dir_patient}" &> ${dir_log}/gd.log)
  ("${DIR_SCRIPT}"/make_vc.sh  -d "${dir_patient}" &> ${dir_log}/vc.log)
  ("${DIR_SCRIPT}"/make_cnv.sh -d "${dir_patient}" &> ${dir_log}/cnv.log)
  ("${DIR_SCRIPT}"/make_report.sh -d "${dir_patient}" &> ${dir_log}/report.log)

  cleanup "${dir_patient}"
}

# get_case relative_patient_dir
function get_case() {
  local dir_patient="${1}"

  if [[ "$(get_config_value annotation.germline "${dir_patient}")" = "True" ]]; then
    echo "somaticGermline"
  else
    echo "somatic"
  fi
}

while getopts d:t:fhs option; do
  case "${option}" in
  t) readonly PARAM_TASK=$OPTARG;;
  d) readonly PARAM_DIR_PATIENT=$OPTARG;;
  f) readonly PARAM_FORCE=true;;
  s) readonly PARAM_SEQ=true;;
  h) usage ;;
  \?)
    echo "Unknown option: -$OPTARG" >&2
    exit 1
    ;;
  :)
    echo "Missing option argument for -$OPTARG" >&2
    exit 1
    ;;
  *)
    echo "Unimplemented option: -$OPTARG" >&2
    exit 1
    ;;
  esac
done

# run script
if [[ -z "${PARAM_DIR_PATIENT}" && -z "${PARAM_TASK}" ]]; then
  for dir in "${DIR_SCRIPT}"/assets/input/*; do
    # get relative dir patient
    DIR_PATIENT=${dir##*/}
  
    # estimate output dir
    CFG_CASE=$(get_case ${DIR_PATIENT})
    DIR_TARGET="${DIR_OUTPUT}/${CFG_CASE}_${DIR_PATIENT}"
    DIR_ANALYSIS="${DIR_TARGET}/Analysis"

    if [[ "${PARAM_FORCE}" || ! -f "${DIR_TARGET}/.processed" ]]; then
      echo "computing ${DIR_PATIENT}"

      if [[ -z "${PARAM_SEQ}" ]]; then
        run_pipe "${DIR_PATIENT}" "${DIR_TARGET}"
      else
        run_pipe_seq "${DIR_PATIENT}" "${DIR_TARGET}"
      fi
      
      # check if report was generated successfully
      if [[ -f "${DIR_ANALYSIS}/${CFG_CASE}_${DIR_PATIENT}_Report.pdf" ]]; then
        touch "${DIR_TARGET}/.processed"
        echo "${DIR_PATIENT} finished"
      else
        echo "${DIR_PATIENT} failed"
      fi
    fi
  done

else
  CFG_CASE=$(get_case ${PARAM_DIR_PATIENT})
  DIR_TARGET="${DIR_OUTPUT}/${CFG_CASE}_${PARAM_DIR_PATIENT}"
  DIR_LOG="${DIR_TARGET}/log"

  readonly DIR_TMP="$(get_config_value common.dirTmp "${PARAM_DIR_PATIENT}")/${PARAM_DIR_PATIENT}"

  # create temporary folder if not existent
  [[ -d "${DIR_TMP}" ]] || mkdir -p "${DIR_TMP}"
  [[ -d "${DIR_LOG}" ]] || mkdir -p "${DIR_LOG}"
  
  # estimate output dir
  CFG_CASE=$(get_case ${PARAM_DIR_PATIENT})
  DIR_TARGET="${DIR_OUTPUT}/${CFG_CASE}_${PARAM_DIR_PATIENT}"
  DIR_ANALYSIS="${DIR_TARGET}/Analysis"
  
  # if already computed, i.e. file .processed exists, only compute again if forced
  if [[ "${PARAM_FORCE}" || ! -f "${DIR_TARGET}/.processed" ]]; then
    if [[ ! -z ${PARAM_TASK} ]]; then
      if [[ ! " ${VALID_TASKS[@]} " =~ " ${PARAM_TASK} " ]]; then
        echo "unknown task: ${PARAM_TASK}"
        echo "use one of the following values: $(join_by ' ' ${VALID_TASKS})"
        exit 1
      fi

      # setup processing
      setup "${PARAM_DIR_PATIENT}" "${DIR_TARGET}"

      # possibility to comfortably run tasks separately
      case "${PARAM_TASK}" in
        td)
          "${DIR_SCRIPT}"/make_alignment.sh -t td -d "${PARAM_DIR_PATIENT}" &> "${DIR_LOG}/td.log"
        ;;
        gd)
          "${DIR_SCRIPT}"/make_alignment.sh -t gd -d "${PARAM_DIR_PATIENT}" &> "${DIR_LOG}/gd.log"
        ;;

        cnv)
          "${DIR_SCRIPT}"/make_cnv.sh -d "${PARAM_DIR_PATIENT}" &> "${DIR_LOG}/cnv.log"
        ;;

        vc)
          "${DIR_SCRIPT}"/make_vc.sh -d "${PARAM_DIR_PATIENT}" &> "${DIR_LOG}/vc.log"
        ;;
        report)
          "${DIR_SCRIPT}"/make_report.sh -d "${PARAM_DIR_PATIENT}" &> "${DIR_LOG}/report.log"
        ;;

        td_gd_parallel)
          ("${DIR_SCRIPT}"/make_alignment.sh -p -t td -d "${dir_patient}" &> ${dir_log}/td.log) &
          ("${DIR_SCRIPT}"/make_alignment.sh -p -t gd -d "${dir_patient}" &> ${dir_log}/gd.log) &
        ;;

        vc_cnv_parallel)
          ("${DIR_SCRIPT}"/make_vc.sh  -p -d "${dir_patient}" &> ${dir_log}/vc.log) &
          ("${DIR_SCRIPT}"/make_cnv.sh -p -d "${dir_patient}" &> ${dir_log}/cnv.log) &
        ;;
      esac

      cleanup "${PARAM_DIR_PATIENT}"
    else
      echo "computing ${PARAM_DIR_PATIENT}"

      if [[ -z "${PARAM_SEQ}" ]]; then
        run_pipe "${PARAM_DIR_PATIENT}" "${DIR_TARGET}"
      else
        run_pipe_seq "${PARAM_DIR_PATIENT}" "${DIR_TARGET}"
      fi

      # check if report was generated successfully
      if [[ -f "${DIR_ANALYSIS}/${CFG_CASE}_${PARAM_DIR_PATIENT}_Report.pdf" ]]; then
        touch "${DIR_TARGET}/.processed"
        echo "${PARAM_DIR_PATIENT} finished"
      else
        echo "${PARAM_DIR_PATIENT} failed"
      fi
    fi
  fi
fi
