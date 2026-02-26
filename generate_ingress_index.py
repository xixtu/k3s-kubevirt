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
    except Exception: return {}

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
                    icon = "fa-link"
                    name_low = name.lower()
                    if "grafana" in name_low: icon = "fa-chart-area"
                    elif "nextcloud" in name_low: icon = "fa-cloud"
                    elif "plex" in name_low: icon = "fa-play"
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
        <title>K3s Compact Index</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
        <style>
            body {{ background-color: #0a0c10; color: #ced4da; font-family: 'Segoe UI', system-ui, sans-serif; }}
            .row-item {{ 
                background: #161b22; 
                border: 1px solid #30363d; 
                transition: all 0.2s ease;
            }}
            .row-item:hover {{ 
                background: #1c2128; 
                border-color: #58a6ff;
                transform: translateX(4px);
            }}
            .ns-tag {{ background: #21262d; border: 1px solid #30363d; }}
            .search-input {{ 
                background: #0d1117; 
                border: 1px solid #30363d; 
            }}
            .search-input:focus {{ border-color: #58a6ff; outline: none; }}
            ::-webkit-scrollbar {{ width: 8px; }}
            ::-webkit-scrollbar-track {{ background: #0a0c10; }}
            ::-webkit-scrollbar-thumb {{ background: #30363d; border-radius: 4px; }}
        </style>
    </head>
    <body class="p-4 md:p-8">
        <div class="max-w-5xl mx-auto">
            
            <header class="flex flex-wrap items-center justify-between mb-8 pb-4 border-b border-gray-800 gap-4">
                <div class="flex items-center gap-3">
                    <div class="w-8 h-8 bg-blue-600 rounded flex items-center justify-center text-white">
                        <i class="fas fa-layer-group text-xs"></i>
                    </div>
                    <h1 class="text-xl font-bold text-white uppercase tracking-wider">K3s Services</h1>
                </div>
                
                <div class="flex items-center gap-4">
                    <input type="text" id="searchInput" placeholder="Filtrer..." 
                           class="search-input px-3 py-1.5 rounded text-sm w-48 md:w-64">
                    <span class="text-[11px] font-mono text-gray-500 uppercase">{now}</span>
                </div>
            </header>

            <div id="content">
    """

    for ns in sorted(data.keys()):
        html += f"""
                <div class="namespace-section mb-6">
                    <div class="flex items-center gap-2 mb-3">
                        <span class="px-2 py-0.5 rounded text-[10px] font-bold ns-tag text-blue-400 uppercase tracking-tighter">Namespace</span>
                        <h2 class="text-sm font-bold text-gray-400">{ns}</h2>
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
        """
        for ing in data[ns]:
            html += f"""
                        <a href="{ing['url']}" target="_blank" class="row-item flex items-center p-3 rounded-md group">
                            <div class="w-8 flex-shrink-0 text-gray-500 group-hover:text-blue-400 transition-colors">
                                <i class="fas {ing['icon']} text-sm"></i>
                            </div>
                            <div class="flex-grow min-w-0">
                                <div class="text-sm font-semibold text-gray-200 truncate">{ing['name']}</div>
                                <div class="text-[11px] text-gray-500 font-mono truncate">{ing['host']}</div>
                            </div>
                            <div class="flex-shrink-0 ml-2 opacity-0 group-hover:opacity-100 transition-opacity">
                                <i class="fas fa-chevron-right text-[10px] text-blue-500"></i>
                            </div>
                        </a>
            """
        html += "</div></div>"

    html += """
            </div>

            <footer class="mt-12 pt-4 border-t border-gray-900 text-[10px] text-gray-600 font-mono flex justify-between uppercase tracking-widest">
                <span>Total: """ + str(sum(len(v) for v in data.values())) + """ Ingress</span>
                <span>K3s Cluster Node-1</span>
            </footer>
        </div>

        <script>
            document.getElementById('searchInput').addEventListener('input', function(e) {
                const term = e.target.value.toLowerCase();
                document.querySelectorAll('.row-item').forEach(card => {
                    const text = card.innerText.toLowerCase();
                    card.style.display = text.includes(term) ? 'flex' : 'none';
                });
                
                document.querySelectorAll('.namespace-section').forEach(section => {
                    const hasVisible = Array.from(section.querySelectorAll('.row-item'))
                                            .some(c => c.style.display !== 'none');
                    section.style.display = hasVisible ? 'block' : 'none';
                });
            });
        </script>
    </body>
    </html>
    """
    
    with open("index.html", "w", encoding="utf-8") as f:
        f.write(html)
    print("✅ Dashboard compact généré.")

if __name__ == "__main__":
    data = get_ingress_data()
    generate_html(data)