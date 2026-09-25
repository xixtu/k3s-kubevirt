#!/usr/bin/env python3
"""
mailpit_blast.py — bombarde un serveur SMTP (Mailpit) de mails de test.

Sujets et contenus aléatoires. Concurrence réglable pour tester l'endurance.
Par défaut : 100 mails vers 127.0.0.1:1025 (le port-forward du lanceur).

Exemples :
    python3 mailpit_blast.py                       # 100 mails, 1 worker
    python3 mailpit_blast.py --count 1000 --workers 10
    python3 mailpit_blast.py --count 500 --workers 8 --per-conn 50
    python3 mailpit_blast.py --count 5 --dry-run    # génère sans envoyer
"""
import argparse, random, smtplib, sys, time, uuid, threading
from concurrent.futures import ThreadPoolExecutor
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from datetime import datetime

WORDS = ("serveur incident sauvegarde réseau cluster noeud certificat latence "
         "réplication supervision alerte maintenance déploiement conteneur volume "
         "authentification proxy passerelle routeur commutateur firmware paquet "
         "tunnel chiffrement quota partition journal sonde métrique tableau seuil "
         "bascule redondance disponibilité charge débit file traitement lot").split()
TAGS = ["INFO", "WARN", "ALERTE", "TEST", "RAPPORT", "SUIVI", "MAINT", "SUPERVISION"]
SUBJECT_TEMPLATES = [
    "[{tag}] {w1} {w2} #{id}",
    "Rapport {id} — {w1} {w2}",
    "{tag} : {w1} sur {w2}",
    "Notification {id} · {w1} {w2} {w3}",
    "Suivi #{id} {w1} {w2}",
    "{w1} {w2} — code {id}",
]

def words(n):
    return " ".join(random.choice(WORDS) for _ in range(n))

def sentence():
    s = words(random.randint(6, 14))
    return s[0].upper() + s[1:] + "."

def make_subject():
    t = random.choice(SUBJECT_TEMPLATES)
    return t.format(id=random.randint(1000, 99999), tag=random.choice(TAGS),
                    w1=random.choice(WORDS), w2=random.choice(WORDS), w3=random.choice(WORDS))

def make_body(seq):
    paras = "\n\n".join(" ".join(sentence() for _ in range(random.randint(2, 5)))
                        for _ in range(random.randint(2, 4)))
    return (f"Mail de test #{seq}\n"
            f"Généré : {datetime.now().isoformat(timespec='seconds')}\n"
            f"Réf : {uuid.uuid4()}\n\n{paras}\n")

def build_message(seq):
    msg = EmailMessage()
    msg["From"] = f"blast-{uuid.uuid4().hex[:8]}@test.local"
    msg["To"] = f"user{random.randint(1, 99999)}@example.test"
    msg["Subject"] = make_subject()
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="blast.test")
    msg["X-Blast-Seq"] = str(seq)
    body = make_body(seq)
    msg.set_content(body)
    if random.random() < 0.4:  # ~40 % en multipart HTML pour varier
        html = "<html><body><h2>{}</h2><pre>{}</pre></body></html>".format(
            msg["Subject"], body.replace("&", "&amp;").replace("<", "&lt;"))
        msg.add_alternative(html, subtype="html")
    return msg

# --- compteurs partagés ---
lock = threading.Lock()
sent = 0
failed = 0
errors = {}

def bump(ok, err=None):
    global sent, failed
    with lock:
        if ok:
            sent += 1
        else:
            failed += 1
            if err:
                errors[err] = errors.get(err, 0) + 1

def worker(seqs, args):
    conn = None
    n_on_conn = 0
    def connect():
        c = smtplib.SMTP(args.host, args.port, timeout=args.timeout)
        c.ehlo()
        return c
    for seq in seqs:
        try:
            if conn is None or (args.per_conn and n_on_conn >= args.per_conn):
                if conn is not None:
                    try: conn.quit()
                    except Exception: pass
                conn = connect(); n_on_conn = 0
            msg = build_message(seq)
            conn.send_message(msg)
            n_on_conn += 1
            bump(True)
        except Exception as e:
            bump(False, type(e).__name__ + ": " + str(e)[:80])
            try:
                if conn: conn.close()
            except Exception: pass
            conn = None; n_on_conn = 0
    if conn is not None:
        try: conn.quit()
        except Exception: pass

def main():
    ap = argparse.ArgumentParser(description="Bombarde Mailpit (SMTP) de mails de test.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=1025)
    ap.add_argument("--count", type=int, default=100, help="nombre de mails (défaut 100)")
    ap.add_argument("--workers", type=int, default=1, help="connexions simultanées")
    ap.add_argument("--per-conn", type=int, default=0,
                    help="mails par connexion avant reconnexion (0 = réutiliser)")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--dry-run", action="store_true", help="génère sans envoyer")
    args = ap.parse_args()

    if args.dry_run:
        for i in range(args.count):
            m = build_message(i + 1)
            print(f"--- #{i+1} From:{m['From']} To:{m['To']}")
            print(f"    Subject: {m['Subject']}")
        print(f"\n[dry-run] {args.count} messages générés, aucun envoi.")
        return

    workers = max(1, min(args.workers, args.count))
    buckets = [[] for _ in range(workers)]
    for i in range(args.count):
        buckets[i % workers].append(i + 1)

    print(f"Cible {args.host}:{args.port} · {args.count} mails · {workers} worker(s)"
          + (f" · reconnexion tous les {args.per_conn}" if args.per_conn else "") + " …")
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(worker, b, args) for b in buckets]
        # affichage de progression
        while any(not f.done() for f in futs):
            time.sleep(0.5)
            with lock:
                done = sent + failed
            print(f"\r  {done}/{args.count}  (ok {sent} / échec {failed})", end="", flush=True)
        for f in futs:
            f.result()
    dt = time.time() - t0
    print(f"\r  {sent+failed}/{args.count}  (ok {sent} / échec {failed})        ")
    rate = sent / dt if dt else 0
    print(f"\nTerminé en {dt:.2f}s · {rate:.1f} mails/s · ok={sent} échec={failed}")
    if errors:
        print("Erreurs :")
        for k, v in sorted(errors.items(), key=lambda x: -x[1]):
            print(f"  {v:>5} × {k}")
    print("Interface Mailpit : http://127.0.0.1:8025")
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
