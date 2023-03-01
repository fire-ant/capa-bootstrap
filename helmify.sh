#!/bin/bash

set -e pipefail

last_n_rel=20
main_menu=$(echo "kubernetes-sigs/cluster-api" && echo "kubernetes-sigs/cluster-api-provider-aws" && curl -sS https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/main/docs/book/src/reference/providers.md | sed -E -n 's/.*\(([^)]*).*/\1/p' | grep -v '\|nested\|azurestackhci\|kubekey\|coxedge\|cloudstack\|outscale\|virtink\|cloud-director\|hetzner\|ibm\|oci\|kubevirt\|nutanix\|cluster-api-aws\.sigs\|gardener\|kubermatic\|openshift\|tree' |sed 's/https\:\/\/github.com\///' | sort | uniq)

stub () {
  mkdir -p .stub/${2}/${3}
  wget -q https://github.com/$1/releases/download/$4/$5 -O .stub/${2}/${3}/${5}
}

helmify () {
  stubpath=.stub/${2}/${3}/${5}
  base=.charts/${2}/${3}/${7}
  path=${base}/Chart.yaml
  cat ${stubpath} | secretref="${8:-'dummy'}" yq 'select(.metadata.name !=env(secretref))' | ./bin/helmify -crd-dir ${base}
  base="${3}"                                   yq -i '(.version=strenv(base))'   ${path}
  app="${3}"                                     yq -i '(.appVersion=strenv(app))' ${path}
  chartname="${7}"                              yq -i '(.name=strenv(chartname))' ${path}
  desc="A Helm Chart for the ${2} ${6} provider" yq -i '(.description=strenv(desc))'  ${path}
  secret=$(cat ${stubpath} | secretref="${8:-'dummy'}" yq 'select(.metadata.name ==env(secretref))')
}
check () {
  echo "please reconfigure each unprocessed variable as a Helm value"
  base=.charts/${2}/${3}/${7}
  grep -r '[A-Z]:=' ${base} &
}

# curl -sSLo - https://github.com/aborilov/crd2cr/releases/download/v0.1.1/crd2cr_0.1.1_Darwin_x86_64.tar.gz | tar xzf - -C /usr/local/bin
crd2cr () {
  mkdir -p .charts/${2}/${3}/${7}/examples
  for crd in .charts/${2}/${3}/${7}/crds; do
    crd2cr --file $crd > .charts/${2}/${3}/${7}/examples/$(basename ${crd})
  done
}

cover(){
echo "cutting a new README for ${1}"
      title=$(echo "${2}"|tr '[:lower:]' '[:upper:]')
      prov="$(tr '[:lower:]' '[:upper:]' <<< ${6:0:1})${6:1}"
      base=.charts/${2}/${3}/README.md
      capip="https://cluster-api.sigs.k8s.io"
      cat << EOF > ${base}
### CAPI ${title} ${prov} Provider Chart

This chart is derived from the ${2} ${6} provider of the [Cluster API]($capip) project 

see https://github.com/${1}

### Values
for Chart Values see [here](charts/${7}/README.md)

#### Notes

Note that Chart releases correlate image versions with CRDs and as such may need to upgrade/replace CRD versions over time.
EOF
if [[ ${8} != "dummy" ]]; then
      cat << EOF >> ${base}
the ${2} project requires a bootstrap secret/credential which is hardcoded to:

${secret}

The credentials will need to be generated separately and managed outside of the chart.
EOF
fi
}
taskfile(){
echo "cutting a new Taskfile.yaml for ${1}"
      base=.charts/${2}/${3}/Taskfile.yaml
      cat << EOF > ${base}
# https://taskfile.dev

version: '3'

tasks:
  purge:
    cmds:
      - echo "Purging..."
      - rm -rf dist

  default:
    deps:
      - purge
    cmds:
      - mkdir dist
      - echo \$CR_PAT | helm registry login ghcr.io --username \$OWNER --password-stdin
      - helm package charts/${1} --destination dist
      - helm push dist/${1}-*.tgz oci://ghcr.io/fire-ant > .digest
      - cat .digest | awk -F "[, ]+" '/Digest/{print \$NF}'
      - cosign sign ghcr.io/fire-ant/${1}@\$(cat .digest | awk -F "[, ]+" '/Digest/{print \$NF}')
    env:
      HELM_EXPERIMENTAL_OCI: 1
      COSIGN_EXPERIMENTAL: "true"

EOF
}

chart() {
  if [[ "$1" == "kubernetes-sigs/cluster-api" ]]; then
    case "$2" in
          *"core"*)             chartname="capi" secretref="dummy" ;;
          *"bootstrap"*)        chartname="capi-kubeadm-bootstrap" secretref="dummy" ;;
          *"control-plane"*)    chartname="capi-kubeadm-control-plane" secretref="dummy" ;;
          *"infrastructure"*)   chartname="capd" secretref="dummy";;
    esac
  elif [[ "$1" == "kubernetes-sigs/cluster-api-provider-aws" ]]; then
    case "$2" in
          *"bootstrap"*)        chartname="capa-bootstrap" secretref="dummy" ;;
          *"control-plane"*)    chartname="capa-control-plane" secretref="dummy" ;;
          *"infrastructure"*)   chartname="capa" secretref="${chartname}-manager-bootstrap-credentials";;
    esac
  else
    case "$1" in
          *"gcp"*)              chartname="capg" secretref="${chartname}-manager-bootstrap-credentials";;
          *"azure"*)            chartname="capz" secretref="${chartname}-manager-bootstrap-credentials";;
          *"vsphere"*)          chartname="capv" secretref="${chartname}-manager-bootstrap-credentials";;
          *"tinkerbell"*)       chartname="capt" secretref="${chartname}-manager-bootstrap-credentials";;
          *"maas"*)             chartname="capm" secretref="${chartname}-manager-bootstrap-credentials";;
          *"metal3"*)           chartname="capm3" secretref="${chartname}-manager-bootstrap-credentials";;
          *"bringyourownhost"*)  chartname="byoh" secretref="${chartname}-manager-bootstrap-credentials";;
          *"microvm"*)          chartname="capmvm" secretref="dummy" ;;
          *"microk8s"*)         chartname="capmk" secretref="dummy";;
          *"hetzner"*)          chartname="caph" secretref="${chartname}-manager-bootstrap-credentials";;
          *"openstack")         chartname="capo" secretref="${chartname}-manager-bootstrap-credentials";;
          *"kubevirt")          chartname="capk" secretref="${chartname}-manager-bootstrap-credentials";;
          *"vcluster")          chartname="capvc" secretref="${chartname}-manager-bootstrap-credentials";;
          *"ocean")             chartname="capdo" secretref="${chartname}-manager-bootstrap-credentials";;
          *"cpem")              chartname="packet" secretref="${chartname}-api-credentials";;
    esac
  fi
}

mkdir -p .stub/
select opt in $main_menu
do
    name=$(echo "${opt}" | sed 's:.*/::')
    echo "Selected project: ${name}"
    releases=$(curl -sS https://api.github.com/repos/${opt}/tags | jq -r ".[] | select(.name) | .name" | grep -v 'rc\|api\|tmp\|hotfix' | head -${last_n_rel})
    select rel in $releases
    do
      nativerel=$( echo "${rel}"| sed 's/v//')
      echo "Selected version: ${nativerel}"
      types=$(curl -s https://api.github.com/repos/${opt}/releases/tags/${rel} | jq -r --arg yaml ${type}-components '.assets[] | select(.name|match($yaml)) | .browser_download_url' | sed 's:.*/::' | grep -v cluster-api)
      alltypes=$(echo "all" && echo ${types} )
      select tp in $alltypes
      do
        echo "Selected provider: ${tp}"
        secretref="dummy"
        if [[ "$tp" == "all" ]]; then
          for t in ${types} ;do
            comp=$(echo $t | sed -n -E 's/-components.yaml//p')
            chart ${opt} ${comp}
            mkdir -p .stub/
            stub ${opt} ${name} ${nativerel} ${rel} ${t} ${comp}
            mkdir -p .charts/
            helmify ${opt} ${name} ${nativerel} ${rel} ${t} ${comp} ${chartname} ${secretref}
            check ${opt} ${name} ${nativerel} ${rel} ${t} ${comp} ${chartname} ${secretref}
            cover ${opt} ${name} ${nativerel} ${rel} ${t} ${comp} ${chartname} ${secretref}
            taskfile ${chartname}
            # crd2cr ${opt} ${name} ${nativerel} ${rel} ${t} ${comp} ${chartname}
            helm-docs --chart-search-root .charts/
            break
          done
        else
          comp=$(echo $tp | sed -n -E 's/-components.yaml//p')
          chart ${opt} ${comp}
          mkdir -p .stub/
          echo "using Provider: ${opt}"
          echo "using type: ${tp}"
          echo "using component: ${comp}"
          stub ${opt} ${name} ${nativerel} ${rel} ${tp} ${comp}
          mkdir -p .charts/
          echo "using secretref: ${secretref}"
          echo "using chartname: ${chartname}"
          helmify ${opt} ${name} ${nativerel} ${rel} ${tp} ${comp} ${chartname} ${secretref}
          check ${opt} ${name} ${nativerel} ${rel} ${tp} ${comp} ${chartname} ${secretref}
          cover ${opt} ${name} ${nativerel} ${rel} ${tp} ${comp} ${chartname} ${secretref}
          taskfile ${chartname}
          # crd2cr ${opt} ${name} ${nativerel} ${rel} ${tp} ${comp} ${chartname}
          helm-docs --chart-search-root .charts/
          break
        fi
        break
      done
      break
    done
    break
done
