#!/bin/bash

# Création du dossier principal et du sous-dossier templates
mkdir -p formbricks/templates

# Génération du fichier Chart.yaml
cat << 'EOF' > formbricks/Chart.yaml
apiVersion: v2
name: formbricks
description: Formbricks Open Source
version: 0.1.0
appVersion: "latest"
EOF

# Génération du fichier values.yaml
cat << 'EOF' > formbricks/values.yaml
domain: "formbricks.app.xixtu.eu"

image:
  repository: ghcr.io/formbricks/formbricks
  tag: latest

postgresql:
  user: formbricks
  password: "ChangeThisSecurePassword123!"
  db: formbricks

env:
  nextAuthSecret: "1234567890abcdef1234567890abcdef"
EOF

# Génération du fichier templates/postgres.yaml
cat << 'EOF' > formbricks/templates/postgres.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: formbricks-postgres
spec:
  selector:
    matchLabels:
      app: formbricks-postgres
  template:
    metadata:
      labels:
        app: formbricks-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_USER
          value: {{ .Values.postgresql.user }}
        - name: POSTGRES_PASSWORD
          value: {{ .Values.postgresql.password }}
        - name: POSTGRES_DB
          value: {{ .Values.postgresql.db }}
---
apiVersion: v1
kind: Service
metadata:
  name: formbricks-postgres
spec:
  ports:
  - port: 5432
  selector:
    app: formbricks-postgres
EOF

# Génération du fichier templates/webapp.yaml
cat << 'EOF' > formbricks/templates/webapp.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: formbricks-webapp
spec:
  selector:
    matchLabels:
      app: formbricks-webapp
  template:
    metadata:
      labels:
        app: formbricks-webapp
    spec:
      containers:
      - name: webapp
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports:
        - containerPort: 3000
        env:
        - name: WEBAPP_URL
          value: "https://{{ .Values.domain }}"
        - name: NEXTAUTH_URL
          value: "https://{{ .Values.domain }}"
        - name: NEXTAUTH_SECRET
          value: {{ .Values.env.nextAuthSecret }}
        - name: DATABASE_URL
          value: "postgresql://{{ .Values.postgresql.user }}:{{ .Values.postgresql.password }}@formbricks-postgres:5432/{{ .Values.postgresql.db }}?schema=public"
---
apiVersion: v1
kind: Service
metadata:
  name: formbricks-webapp
spec:
  ports:
  - port: 3000
  selector:
    app: formbricks-webapp
EOF

# Génération du fichier templates/ingress.yaml
cat << 'EOF' > formbricks/templates/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: formbricks-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - {{ .Values.domain }}
    secretName: formbricks-tls-certs
  rules:
  - host: {{ .Values.domain }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: formbricks-webapp
            port:
              number: 3000
EOF

echo "Dossiers créés et fichiers générés avec succès. Tu peux lancer : helm install my-formbricks ./formbricks --namespace formbricks"
