#!/usr/bin/env bash
# Restart the three RIC components most commonly involved in instability.
# Run this from inside the LXC container if pods are stuck or failing.

kubectl rollout restart deployment/deployment-ricplt-e2mgr -n ricplt
kubectl rollout restart deployment/deployment-ricplt-e2term-alpha -n ricplt
kubectl rollout restart deployment/deployment-ricplt-rtmgr -n ricplt

kubectl get pods -n ricplt

kubectl rollout status deployment/deployment-ricplt-e2mgr -n ricplt
kubectl rollout status deployment/deployment-ricplt-e2term-alpha -n ricplt
kubectl rollout status deployment/deployment-ricplt-rtmgr -n ricplt
