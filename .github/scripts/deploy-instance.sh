#!/bin/bash

current_datetime=$(echo -n ${CURRENT_DATE} | md5sum | head -c 10)
echo "NAMESPACE : ci-{{INSTANCE}}-ns-pm4"
helm repo add processmaker ${HELM_REPO} --username ${HELM_USERNAME} --password ${HELM_PASSWORD} && helm repo update

if ! kubectl get namespace/ci-{{INSTANCE}}-ns-pm4 >/dev/null 2>&1; then
    echo "New instance. Creating Namespace"
    kubectl create namespace ci-{{INSTANCE}}-ns-pm4
    echo "Creating DB"
    # Use admin password from secrets
    echo "Update instance yamls"
    
    export RDS_ADMIN_PASSWORD=$RDS_ADMIN_PASSWORD
    export RDS_ADMIN_USERNAME=$RDS_ADMIN_USERNAME
    sed -i "s/{{MYSQL_USERNAME}}/$RDS_ADMIN_USERNAME/" .github/templates/db.yaml
    sed -i "s/{{MYSQL_PASSWORD}}/$RDS_ADMIN_PASSWORD/" .github/templates/db.yaml
    echo "Creating DB :: pm4_ci-{{INSTANCE}}"
    cat .github/templates/db.yaml
    kubectl apply -f .github/templates/db.yaml --v=4
    
    while true; do
        DBSTATUS=$(kubectl get job mysql-setup-job-ci-{{INSTANCE}} -o jsonpath='{.status.succeeded}')
        if [[ "$DBSTATUS" == "1" ]]; then
            echo "MySQL Setup Job has completed."
            break
        else
            echo "MySQL Setup Job is still running. Checking again in 10 seconds..."
            sleep 10
        fi
    done
    
    echo "Removing Job"
    kubectl delete job mysql-setup-job-ci-{{INSTANCE}}
    echo "Deploying Instance :: ci-{{INSTANCE}}"
    sed -i "s/{{MYSQL_PASSWORD}}/$RDS_ADMIN_PASSWORD/" .github/templates/instance.yaml
    sed -i "s/{{MYSQL_USER}}/$RDS_ADMIN_USERNAME/" .github/templates/instance.yaml
    cat .github/templates/instance.yaml
    # Evaluate the command and store the result
    APP_VERSION=$(echo "$CI_PROJECT-$CI_PACKAGE_BRANCH" | sed "s;/;-;g" | sed "s/refs-heads-//g")

    helm install --timeout 75m -f .github/templates/instance.yaml ci-{{INSTANCE}} processmaker/enterprise \
        --set deploy.pmai.openaiApiKey=${OPENAI_API_KEY} \
        --set analytics.awsAccessKey=${ANALYTICS_AWS_ACCESS_KEY} \
        --set analytics.awsSecretKey=${ANALYTICS_AWS_SECRET_KEY} \
        --set dockerRegistry.password=${REGISTRY_PASSWORD} \
        --set dockerRegistry.url=${REGISTRY_HOST} \
        --set dockerRegistry.username=${REGISTRY_USERNAME} \
        --set twilio.sid=${TWILIO_SID} \
        --set twilio.token=${TWILIO_TOKEN} \
        --set appVersion=${APP_VERSION} \
        --version ${versionHelm}
else
    echo "Instance exists. Running upgrade and bouncing pods"
    helm upgrade --timeout 60m ci-{{INSTANCE}} processmaker/enterprise --version ${versionHelm}
    
    #Bounce pods
    webPod=$(kubectl get pods -n ci-{{INSTANCE}}-ns-pm4|grep web|awk '{print $1}')
    schedulerPod=$(kubectl get pods -n ci-{{INSTANCE}}-ns-pm4|grep scheduler|awk '{print $1}')
    queuePod=$(kubectl get pods -n ci-{{INSTANCE}}-ns-pm4|grep queue|awk '{print $1}')
    kubectl delete pod $webPod $schedulerPod $queuePod -n ci-{{INSTANCE}}-ns-pm4
fi

if [ "$MULTITENANCY" = "true" ]; then
    export INSTANCE_URL="https://tenant-1.ci-{{INSTANCE}}$DOM_EKS"
else
    export INSTANCE_URL="https://ci-{{INSTANCE}}$DOM_EKS"
fi
echo "INSTANCE_URL=${INSTANCE_URL}" >> "$GITHUB_ENV"
./pm4-k8s-distribution/images/pm4-tools/pm wait-for-instance-ready
