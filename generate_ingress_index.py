from kubernetes import client, config
from collections import defaultdict
import datetime

def get_ingress_data():
    # Charge la config depuis ~/.kube/config ou le compte de service du pod
    try:
        config.load_kube_config()
    except:
        config.load_incluster_config()

    v1_networking = client.NetworkingV1Api()
    
    # Récupération de tous les ingress
    ret = v1_networking.list_ingress_for_all_namespaces()
    
    grouped_ingress = defaultdict(list)
    
    for i in ret.items:
        namespace = i.metadata.namespace
        name = i.metadata.name
        
        # On parcourt les règles pour extraire les URLs
        if i.spec.rules:
            for rule in i.spec.rules:
                host = rule.host
                protocol = "https" if i.spec.tls else "http"
                url = f"{protocol}://{host}"
                grouped_ingress[namespace].append({
                    "name": name,
                    "url": url
                })
    return grouped_ingress

def generate_html(data):
    now = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
    
    html_content = f"""
    <!DOCTYPE html>
    <html lang="fr">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>K3s Ingress Index</title>
        <style>
            body {{ font-family: sans-serif; background: #f4f7f6; color: #333; padding: 20px; }}
            .container {{ max-width: 800px; margin: auto; }}
            h1 {{ color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }}
            .namespace-section {{ background: white; margin-bottom: 20px; padding: 15px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }}
            .namespace-title {{ color: #e67e22; margin-top: 0; text-transform: uppercase; font-size: 0.9em; }}
            ul {{ list-style: none; padding: 0; }}
            li {{ margin: 10px 0; }}
            a {{ text-decoration: none; color: #3498db; font-weight: bold; }}
            a:hover {{ text-decoration: underline; }}
            .footer {{ font-size: 0.8em; color: #7f8c8d; margin-top: 20px; }}
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Cluster Ingress Index</h1>
            <p>Services disponibles sur le cluster :</p>
    """

    for ns, ingresses in sorted(data.items()):
        html_content += f'<div class="namespace-section">'
        html_content += f'<h2 class="namespace-title">Namespace: {ns}</h2><ul>'
        for ing in ingresses:
            html_content += f'<li>{ing["name"]} : <a href="{ing["url"]}" target="_blank">{ing["url"]}</a></li>'
        html_content += "</ul></div>"

    html_content += f"""
            <div class="footer">Généré le {now}</div>
        </div>
    </body>
    </html>
    """
    
    with open("index.html", "w", encoding="utf-8") as f:
        f.write(html_content)
    print("✅ Fichier index.html généré avec succès.")

if __name__ == "__main__":
    data = get_ingress_data()
    generate_html(data)