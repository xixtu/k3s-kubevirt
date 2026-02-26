import os
from kubernetes import client, config
from collections import defaultdict
import datetime

def get_ingress_data():
    # Tentative de chargement de la config K3s standard si KUBECONFIG n'est pas défini
    k3s_config = "/etc/rancher/k3s/k3s.yaml"
    try:
        if "KUBECONFIG" not in os.environ and os.path.exists(k3s_config):
            config.load_kube_config(config_file=k3s_config)
        else:
            config.load_kube_config()
    except Exception as e:
        print(f"⚠️ Erreur config : {e}. Tentative in-cluster...")
        try:
            config.load_incluster_config()
        except:
            print("❌ Impossible de trouver une configuration Kubernetes.")
            return {}

    v1_networking = client.NetworkingV1Api()
    try:
        ret = v1_networking.list_ingress_for_all_namespaces()
    except Exception as e:
        print(f"❌ Erreur lors de la lecture des Ingress : {e}")
        return {}
    
    grouped_ingress = defaultdict(list)
    for i in ret.items:
        ns = i.metadata.namespace
        name = i.metadata.name
        if i.spec.rules:
            for rule in i.spec.rules:
                if rule.host:
                    proto = "https" if i.spec.tls else "http"
                    grouped_ingress[ns].append({
                        "name": name,
                        "url": f"{proto}://{rule.host}",
                        "host": rule.host
                    })
    return grouped_ingress

def generate_html(data):
    now = datetime.datetime.now().strftime("%d %b %Y - %H:%M")
    
    html_template = f"""
    <!DOCTYPE html>
    <html lang="fr">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>K3s Services Index</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
        <style>
            body {{ background-color: #0f172a; color: #f8fafc; font-family: 'Inter', sans-serif; }}
            .glass {{ background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.1); }}
            .card:hover {{ transform: translateY(-5px); transition: all 0.3s ease; box-shadow: 0 10px 20px rgba(0,0,0,0.3); }}
            .badge-ns {{ background: linear-gradient(90deg, #3b82f6, #2dd4bf); }}
        </style>
    </head>
    <body class="p-4 md:p-10">
        <div class="max-w-6xl mx-auto">
            <header class="flex flex-col md:flex-row justify-between items-center mb-12 gap-4">
                <div>
                    <h1 class="text-4xl font-extrabold tracking-tight text-white flex items-center gap-3">
                        <i class="fas fa-cubes text-blue-400"></i> K3s Ingress Hub
                    </h1>
                    <p class="text-slate-400 mt-2">Index automatique des services exposés</p>
                </div>
                <div class="text-right">
                    <span class="px-4 py-2 rounded-full glass text-sm font-mono text-blue-300">
                        <i class="far fa-clock mr-2"></i>{now}
                    </span>
                </div>
            </header>

            <div class="space-y-12">
    """

    if not data:
        html_template += '<div class="text-center py-20 glass rounded-3xl"><i class="fas fa-search fa-3x mb-4 text-slate-600"></i><p>Aucun Ingress trouvé.</p></div>'

    for ns in sorted(data.keys()):
        html_template += f"""
                <section>
                    <div class="flex items-center gap-4 mb-6">
                        <h2 class="text-xl font-bold uppercase tracking-widest text-slate-300">{ns}</h2>
                        <div class="h-px flex-grow bg-slate-800"></div>
                        <span class="text-xs font-mono text-slate-500">{len(data[ns])} service(s)</span>
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        """
        for ing in data[ns]:
            html_template += f"""
                        <a href="{ing['url']}" target="_blank" class="card glass p-6 rounded-2xl flex flex-col justify-between group">
                            <div class="flex justify-between items-start mb-4">
                                <div class="w-12 h-12 rounded-xl bg-slate-800 flex items-center justify-center text-blue-400 group-hover:bg-blue-500 group-hover:text-white transition-colors">
                                    <i class="fas fa-link fa-lg"></i>
                                </div>
                                <i class="fas fa-external-link-alt text-slate-600 group-hover:text-blue-400"></i>
                            </div>
                            <div>
                                <h3 class="font-bold text-lg text-white mb-1 truncate">{ing['name']}</h3>
                                <p class="text-sm text-slate-400 font-mono truncate">{ing['host']}</p>
                            </div>
                        </a>
            """
        html_template += "</div></section>"

    html_template += """
            </div>
            
            <footer class="mt-20 pt-8 border-t border-slate-800 text-center text-slate-500 text-sm">
                <p>Généré dynamiquement par l'API Kubernetes • <i class="fab fa-python"></i> Python v3</p>
            </footer>
        </div>
    </body>
    </html>
    """
    
    with open("index.html", "w", encoding="utf-8") as f:
        f.write(html_template)
    print(f"✨ Page de bord générée : index.html ({len(data)} namespaces trouvés)")

if __name__ == "__main__":
    data = get_ingress_data()
    generate_html(data)