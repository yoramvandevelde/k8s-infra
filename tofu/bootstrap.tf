resource "null_resource" "bootstrap" {
  depends_on = [talos_cluster_kubeconfig.this]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/output
      tofu output -raw kubeconfig > ${path.module}/output/kubeconfig
      chmod 600 ${path.module}/output/kubeconfig
      bash ${path.module}/scripts/bootstrap.sh
    EOT
  }
}
