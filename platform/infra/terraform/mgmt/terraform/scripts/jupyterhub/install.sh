JUPYTERHUB_DIR="."

sed "s/DOMAIN_NAME/${DOMAIN_NAME}/g" ${JUPYTERHUB_DIR}/values.yaml.tmpl >${JUPYTERHUB_DIR}/values.yaml
