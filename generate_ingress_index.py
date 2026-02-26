import os
from kubernetes import client, config
from collections import defaultdict
import datetime

def get_ingress_data():
    k3s_config = "/etc/rancher/k3s/k3s.yaml"
    try:
        if "KUBECONFIG" not in os.environ and os.path.exists(k3s_config):
            config.load_kube_config(config_file=k3s_config)
        else:
            config.load_kube_config()
    except Exception as e:
        print(f"⚠️ Erreur config : {e}")
        return {}

    v1_networking = client.NetworkingV1Api()
    try:
        ret = v1_networking.list_ingress_for_all_namespaces()
    except Exception: return {}
    
    grouped = defaultdict(list)
    for i in ret.items:
        ns = i.metadata.namespace
        name = i.metadata.name
        if i.spec.rules:
            for rule in i.spec.rules:
                if rule.host:
                    proto = "https" if i.spec.tls else "http"
                    # Logique d'icône simple basée sur le nom
                    icon = "fa-network-wired"
                    name_low = name.lower()
                    if "grafana" in name_low: icon = "fa-chart-line"
                    elif "nextcloud" in name_low: icon = "fa-cloud"
                    elif "plex" in name_low or "video" in name_low: icon = "fa-play-circle"
                    elif "home" in name_low: icon = "fa-home"
                    elif "git" in name_low: icon = "fa-code-branch"
                    
                    grouped[ns].append({
                        "name": name,
                        "url": f"{proto}://{rule.host}",
                        "host": rule.host,
                        "icon": icon
                    })
    return grouped

def generate_html(data):
    now = datetime.datetime.now().strftime("%H:%M - %d/%m/%Y")
    
    html = f"""
    <!DOCTYPE html>
    <html lang="fr">
    <head>
        <meta charset="UTF-8">
        <title>K3s Nexus Dashboard</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
        <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;600;800&display=swap" rel="stylesheet">
        <style>
            body {{ 
                background: radial-gradient(circle at top left, #1e293b, #0f172a);
                color: #f8fafc; font-family: 'Plus Jakarta Sans', sans-serif;
                min-height: 100vh;
            }}
            .glass-card {{
                background: rgba(255, 255, 255, 0.03);
                backdrop-filter: blur(12px);
                border: 1px solid rgba(255, 255, 255, 0.08);
                transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
            }}
            .glass-card:hover {{
                background: rgba(255, 255, 255, 0.07);
                border-color: #3b82f6;
                transform: translateY(-8px) scale(1.02);
            }}
            .glow-blue {{ box-shadow: 0 0 20px rgba(59, 130, 246, 0.15); }}
            .status-dot {{
                animation: pulse 2s infinite;
            }}
            @keyframes pulse {{
                0% {{ opacity: 1; transform: scale(1); }}
                50% {{ opacity: 0.5; transform: scale(1.2); }}
                100% {{ opacity: 1; transform: scale(1); }}
            }}
            .search-bar {{
                background: rgba(15, 23, 42, 0.6);
                border: 1px solid rgba(59, 130, 246, 0.3);
            }}
            .search-bar:focus {{ border-color: #3b82f6; outline: none; box-shadow: 0 0 15px rgba(59, 130, 246, 0.4); }}
        </style>
    </head>
    <body class="p-6 md:p-12">
        <div class="max-w-7xl mx-auto">
            
            <div class="flex flex-col md:flex-row justify-between items-end mb-16 gap-8">
                <div>
                    <div class="flex items-center gap-3 mb-2">
                        <span class="px-3 py-1 rounded-full bg-blue-500/10 text-blue-400 text-xs font-bold tracking-widest uppercase">Cluster Live</span>
                        <span class="text-slate-500 text-sm font-mono">{now}</span>
                    </div>
                    <h1 class="text-5xl font-extrabold text-white tracking-tight">K3s <span class="text-transparent bg-clip-text bg-gradient-to-r from-blue-400 to-cyan-400">Nexus</span></h1>
                </div>
                
                <div class="w-full md:w-96 relative">
                    <i class="fas fa-search absolute left-4 top-1/2 -translate-y-1/2 text-slate-500"></i>
                    <input type="text" id="searchInput" placeholder="Rechercher un service..." 
                           class="search-bar w-full pl-12 pr-4 py-4 rounded-2xl text-white transition-all">
                </div>
            </div>

            <div id="content">
    """

    for ns in sorted(data.keys()):
        html += f"""
                <div class="namespace-group mb-16">
                    <div class="flex items-center gap-4 mb-8">
                        <h2 class="text-2xl font-semibold text-slate-200">{ns}</h2>
                        <div class="h-px flex-grow bg-gradient-to-r from-slate-800 to-transparent"></div>
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        """
        for ing in data[ns]:
            html += f"""
                        <a href="{ing['url']}" target="_blank" class="service-card glass-card p-6 rounded-3xl group">
                            <div class="flex justify-between items-start mb-6">
                                <div class="p-3 rounded-2xl bg-blue-500/10 text-blue-400 group-hover:bg-blue-500 group-hover:text-white transition-all duration-500">
                                    <i class="fas {ing['icon']} fa-xl"></i>
                                </div>
                                <div class="flex items-center gap-2">
                                    <span class="status-dot w-2 h-2 rounded-full bg-emerald-500 shadow-[0_0_8px_#10b981]"></span>
                                    <span class="text-[10px] font-bold text-emerald-500 uppercase">Online</span>
                                </div>
                            </div>
                            <h3 class="text-xl font-bold text-white mb-2 group-hover:text-blue-300 transition-colors">{ing['name']}</h3>
                            <p class="text-sm text-slate-500 font-mono truncate">{ing['host']}</p>
                            
                            <div class="mt-6 flex items-center text-xs font-bold text-blue-400 opacity-0 group-hover:opacity-100 transition-opacity">
                                OUVRIR LE SERVICE <i class="fas fa-arrow-right ml-2"></i>
                            </div>
                        </a>
            """
        html += "</div></div>"

    html += """
            </div>

            <footer class="mt-32 pb-12 text-center">
                <div class="inline-flex items-center gap-6 px-8 py-4 rounded-2xl glass-card text-slate-500 text-sm">
                    <span><i class="fas fa-microchip mr-2"></i> K3s Cluster</span>
                    <span class="w-1 h-1 rounded-full bg-slate-700"></span>
                    <span><i class="fab fa-python mr-2"></i> Automatisé</span>
                </div>
            </footer>
        </div>

        <script>
            document.getElementById('searchInput').addEventListener('input', function(e) {
                const term = e.target.value.toLowerCase();
                document.querySelectorAll('.service-card').forEach(card => {
                    const name = card.querySelector('h3').textContent.toLowerCase();
                    const host = card.querySelector('p').textContent.toLowerCase();
                    const isVisible = name.includes(term) || host.includes(term);
                    card.style.display = isVisible ? 'block' : 'none';
                });
                
                // Cacher les titres de namespace vides
                document.querySelectorAll('.namespace-group').forEach(group => {
                    const hasVisibleCards = Array.from(group.querySelectorAll('.service-card'))
                                                 .some(c => c.style.display !== 'none');
                    group.style.display = hasVisibleCards ? 'block' : 'none';
                });
            });
        </script>
    </body>
    </html>
    """
    
    with open("index.html", "w", encoding="utf-8") as f:
        f.write(html)
    print("🚀 Dashboard 'Nexus' généré avec succès !")

if __name__ == "__main__":
    data = get_ingress_data()
    generate_html(data)