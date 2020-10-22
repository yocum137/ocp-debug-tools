#/bin/bash

export DIR=/tmp/enableAdminApi

# Functions
reset_state() {
echo "Terminating port-forward process."
# Find and kill the port-forward process
export PF_PID=`ps auxww | grep "openshift-monitoring port-forward" | awk '{print $2}'`
/usr/bin/kill $PF_PID

echo "Scaling up CMO..."
# Scale up the Operator deployment
oc -n openshift-monitoring  scale deployment.apps/cluster-monitoring-operator --replicas=1

echo "Placing CMO back into managed state..."
oc -n openshift-monitoring patch clusterversion version --type json -p '[{"op":"remove", "path":"/spec/overrides"}]'

popd
}

# Main

oc cluster-info

echo "If this is not correct, ctl-C now otherwise press Enter."
read input

mkdir -p $DIR
pushd $DIR

echo "Placing CMO into unmanaged state..."
# Set CMO to unmanaged state

cat <<EOF >debug-cmo-patch.yaml
- op: add
  path: /spec/overrides
  value:
  - kind: Deployment
    group: apps/v1
    name: cluster-monitoring-operator
    namespace: openshift-monitoring
    unmanaged: true
EOF

oc -n openshift-monitoring patch clusterversion version --type json -p "$(cat debug-cmo-patch.yaml)"

echo "Scaling down CMO..."
# Scale down the Operator deployment
oc -n openshift-monitoring  scale deployment.apps/cluster-monitoring-operator --replicas=0

echo "Setting enableAdminAPI: true"
# Patch sts to enable admin API
oc -n openshift-monitoring patch prometheus k8s --type merge --patch '{"spec":{"enableAdminAPI":true}}'

echo "Waiting for prometheus-k8s pods to restart"
# Wait for the pods to restart
sleep 20

echo "Verifying enableAdminAPI is enabled"
# Verify patch worked
oc get sts prometheus-k8s   -o yaml | grep admin &> /dev/null
if [ $? -ne 0 ]; then
	echo  "Something went wrong setting enableAdminAPI.  Exiting."
	reset_state
	exit 1
fi

echo "Enable port-forwarding to access Admin API"
# Enable port-forwarding to the admin api
oc -n openshift-monitoring port-forward svc/prometheus-operated 9090 &
sleep 10

echo "Creating the snapshot to the local system."
# Create the snapshot
export PROMDB_SNAP=`curl -XPOST http://localhost:9090/api/v2/admin/tsdb/snapshot | awk -F\" '{print $4}'`

if [ $? -ne 0 ]; then
	echo  "Something went wrong creating the snapshot.  Exiting."
	reset_state
	exit 1
fi

# Find the snapshot - it's in one of the prometheus-k8s pods
for pod in `oc -n openshift-monitoring get pods | grep prometheus-k8s | awk '{print $1}'`; do oc rsh  $pod ls /prometheus/snapshots/$PROMDB_SNAP/ &> /dev/null; if [ $? -eq 0 ]; then export PROMDB_POD=$pod; continue; fi; done

echo "Preparing to copy the snapshot locally."
# Check that we have enough disk space, locally
export LOCAL_SPACE=`df . | grep -v Used | awk '{print $3}'`

export PROMDB_SIZE=`oc -n openshift-monitoring rsh $PROMDB_POD du -sk /prometheus/snapshots/$PROMDB_SNAP/ 2> /dev/null | awk '{print $1}'`

if [ $LOCAL_SPACE -gt $PROMDB_SIZE ]; then
	echo "Sufficient local storage space exists.  Continuing..."
else
	echo "Not enough local storage space exists.  Set DIR to a filesystem with at least $PROMDB_SIZE kilo-bytes before re-running this."
	reset_state
	exit 1
fi

echo "Copying promdb to local disk.  This will take some time.  Please be patient."
# Copy the snapshot locally, tar and compress
oc rsync -n openshift-monitoring ${PROMDB_POD}:/prometheus/snapshots/${PROMDB_SNAP} -c prometheus .
tar -cvzf promdb_${PROMDB_SNAP}.tgz ${PROMDB_SNAP}

if [ $? -eq 0 ]; then
	echo "Copy complete!"
else
	echo "Something went wrong.  Exiting."
	reset_state
	exit 1
fi

reset_state

echo ""
echo "Prometheus DB Snapshot created at ${DIR}/promdb_${PROMDB_SNAP}.tgz"
echo "Exiting."
