argopatch() {
  kubectl --kubeconfig ./output/kubeconfig -n argocd patch application "$1" --type=json -p='[
    {"op":"add","path":"/operation","value":{"initiatedBy":{"username":"kubectl"},"sync":{"revision":"HEAD","prune":true,"syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}
  ]'
}
