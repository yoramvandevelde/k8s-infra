resource "null_resource" "bootstrap" {
  depends_on = [talos_cluster_kubeconfig.this]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/../output
      echo '${talos_cluster_kubeconfig.this.kubeconfig_raw}' > ${path.module}/../output/kubeconfig
      echo '${data.talos_client_configuration.this.talos_config}' > ${path.module}/../output/talosconfig
      chmod 600 ${path.module}/../output/kubeconfig
      chmod 600 ${path.module}/../output/talosconfig
      docker run --rm \
        -v ${path.module}/../output:/output \
        -v ${path.module}/../scripts:/scripts \
        -v ${path.module}/../k3s-gitops:/k3s-gitops \
        -e SEALED_SECRETS_PASSPHRASE='${var.sealed_secrets_passphrase}' \
        -e KUBECONFIG=/output/kubeconfig \
        -e TALOSCONFIG=/output/talosconfig \
        ghcr.io/yoramvandevelde/bootstrap:1.0.0 \
        /scripts/bootstrap.sh
    EOT
  }
}
