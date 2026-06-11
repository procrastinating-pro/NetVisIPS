#!/bin/bash

# ==============================================================================
# CYBERPUNK NETWORK UPLINK & FIREWALL - MASTER INSTALLER
# ==============================================================================

echo -e "\e[32m[*] Inicjalizacja instalatora Cyberpunk-NetVis...\e[0m"

# 1. Instalacja zależności systemowych
echo -e "\e[34m[*] KROK 1: Instalacja pakietów systemowych (może wymagać hasła root)...\e[0m"
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip libpcap-dev iproute2

# 2. Tworzenie środowiska wirtualnego
echo -e "\e[34m[*] KROK 2: Konfiguracja izolowanego środowiska Python (.venv)...\e[0m"
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate

# 3. Instalacja modułów Pythona
echo -e "\e[34m[*] KROK 3: Instalacja modułów sieciowych (Scapy, Websockets, OUI)...\e[0m"
pip install --upgrade pip
pip install websockets scapy geoip2 mac-vendor-lookup

# 4. Wstępne pobranie bazy MAC
echo -e "\e[34m[*] KROK 4: Kompilacja bazy danych IEEE MAC OUI...\e[0m"
python3 -c "from mac_vendor_lookup import MacLookup; MacLookup().update_vendors()"

echo -e "\e[34m[*] KROK 5: Generowanie struktury plików...\e[0m"

# ==============================================================================
# GENEROWANIE PLIKU: run.sh
# ==============================================================================
cat << 'EOF' > run.sh
#!/bin/bash

if [ -f ".venv/bin/activate" ]; then
    echo "[*] Aktywacja środowiska wirtualnego (.venv)..."
    source .venv/bin/activate
else
    echo "[BŁĄD] Nie znaleziono środowiska wirtualnego w folderze .venv!"
    exit 1
fi

echo "[*] Uruchamianie Zapory (IPS) w tle..."
sudo $(which python3) server.py &
PYTHON_PID=$!

echo "[*] Trwa ładowanie globalnych baz danych IEEE OUI..."

# Ciche (pasywne) nasłuchiwanie w tabeli routingu systemu za pomocą 'ss'
while ! ss -tuln | grep -q ":8765"; do
    sleep 0.5
done

echo "[+] Tarcza w pełni operacyjna. Nawiązywanie połączenia UI..."

if command -v xdg-open > /dev/null; then
    if [ "$EUID" -eq 0 ]; then
        sudo -u ${SUDO_USER:-$USER} xdg-open index.html
    else
        xdg-open index.html
    fi
else
    echo "[-] Otwórz plik index.html ręcznie w przeglądarce."
fi

wait $PYTHON_PID
EOF
chmod +x run.sh

# ==============================================================================
# GENEROWANIE PLIKU: server.py
# ==============================================================================
cat << 'EOF' > server.py
import asyncio
import websockets
import json
import random
import os
import socket
import time
from scapy.all import sniff, IP, TCP, UDP, DNS, DNSRR, srp, Ether, ARP

try:
    from mac_vendor_lookup import MacLookup
    mac_lookup = MacLookup()
    print("[*] Trwa aktualizacja globalnej bazy producentów sprzętu (IEEE OUI)...")
    mac_lookup.update_vendors()
    print("[+] Baza MAC załadowana pomyślnie.")
except ImportError:
    mac_lookup = None
    print("[-] Uwaga: Brak biblioteki mac-vendor-lookup.")
except Exception as e:
    print(f"[-] Uwaga: Błąd aktualizacji bazy MAC: {e}")

try:
    import geoip2.database
    if os.path.exists('GeoLite2-City.mmdb'):
        geo_reader = geoip2.database.Reader('GeoLite2-City.mmdb')
        print("[+] Sukces: Baza GeoIP załadowana.")
    else:
        geo_reader = None
except ImportError:
    geo_reader = None

UI_BLACKLIST = ["142.250.", "172.217.", "204.79.", "13.107.", "23.212.", "34.117."]
UI_WHITELIST = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112"]

BLOCKLIST_SUBNETS = list(UI_BLACKLIST)
WHITELIST_IPS = list(UI_WHITELIST)

COMMON_PORTS = {
    20: "FTP-DATA", 21: "FTP", 22: "SSH", 23: "TELNET",
    25: "SMTP", 53: "DNS", 80: "HTTP", 110: "POP3",
    123: "NTP", 143: "IMAP", 443: "HTTPS", 465: "SMTPS",
    993: "IMAPS", 995: "POP3S", 3306: "MYSQL", 3389: "RDP",
    5432: "POSTGRES", 8080: "HTTP-ALT"
}

# =====================================================
# LOKALNA BAZA SPRZĘTU SOVEREIGN/DIY (Omija bazę IEEE)
# =====================================================
MANUAL_DEVICES = {
    "192.168.1.15": "Drukarka 3D (Voron/Klipper)",
    "192.168.1.20": "ESP32 (Hydroponika)",
    "192.168.1.50": "Warsztat (Ubuntu Server)"
}

connected_clients = set()
main_loop = None

dns_cache = {}
udp_throttle_cache = {}
bandwidth_stats = {"in": 0, "out": 0}

traffic_monitor = {}
AUTOBAN_THRESHOLD = 80       
AUTOBAN_TIME_WINDOW = 2.0    
pending_suspects = set()

def is_whitelisted(ip):
    for w_ip in WHITELIST_IPS:
        if ip.startswith(w_ip):
            return True
    return False

def get_device_info(ip, mac):
    hostname = "Unknown"
    vendor = "Unknown"
    os_info = ""

    # 1. Ręczne nadpisanie (Lokalna baza DIY)
    if ip in MANUAL_DEVICES:
        return MANUAL_DEVICES[ip], "Sovereign/DIY Hardware"

    # 2. Pasywne Rozpoznawanie Sprzętu
    if mac_lookup:
        try:
            full_vendor = mac_lookup.lookup(mac)
            vendor = full_vendor.split(' ')[0].split(',')[0]
        except Exception:
            pass

    # 3. Aktywne Rozpoznawanie Nazwy
    try:
        socket.setdefaulttimeout(0.2)
        hostname = socket.gethostbyaddr(ip)[0]
    except Exception:
        hostname = "Unknown"

    # 4. Aktywny Skan Portów
    def check_port(port):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.05)
            result = s.connect_ex((ip, port))
            s.close()
            return result == 0
        except:
            return False

    if check_port(445) or check_port(139):
        os_info = "Windows"
    elif check_port(22):
        os_info = "Linux/Unix"
    elif check_port(80) or check_port(443):
        os_info = "Web/IoT"

    # 5. Sklejanie Wyników
    if vendor != "Unknown" and os_info:
        final_os = f"{vendor} ({os_info})"
    elif vendor != "Unknown":
        final_os = vendor
    elif os_info:
        final_os = f"Unknown Hardware ({os_info})"
    else:
        final_os = "Unknown"
        
    if "Unknown" in final_os and hostname != "Unknown":
        h_lower = hostname.lower()
        if "esp" in h_lower or "wled" in h_lower:
            final_os = "ESP Node (IoT)"
        elif "pi" in h_lower or "raspberry" in h_lower:
            final_os = "Raspberry Pi"

    return hostname, final_os

def get_lan_devices():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()
        subnet = local_ip.rsplit('.', 1)[0] + '.0/24'
        
        ans, _ = srp(Ether(dst="ff:ff:ff:ff:ff:ff")/ARP(pdst=subnet), timeout=1.5, verbose=0)
        devices = []
        for snd, rcv in ans:
            ip = rcv.psrc
            mac = rcv.hwsrc
            hostname, os_name = get_device_info(ip, mac)
            devices.append({"ip": ip, "mac": mac, "hostname": hostname, "os": os_name})
        return {"subnet": subnet, "devices": devices}
    except Exception as e:
        return {"subnet": "Unknown", "devices": []}

async def lan_radar_loop():
    while True:
        lan_data = await asyncio.get_running_loop().run_in_executor(None, get_lan_devices)
        if connected_clients:
            payload = {"type": "lan_scan", "subnet": lan_data["subnet"], "devices": lan_data["devices"]}
            msg = json.dumps(payload)
            for client in connected_clients.copy():
                try:
                    await client.send(msg)
                except Exception:
                    pass
        await asyncio.sleep(15)

async def send_lists_update():
    if connected_clients:
        payload = {"type": "lists", "blacklist": UI_BLACKLIST, "whitelist": UI_WHITELIST}
        msg = json.dumps(payload)
        for client in connected_clients.copy():
            try:
                await client.send(msg)
            except Exception:
                pass

async def broadcast_bandwidth():
    while True:
        await asyncio.sleep(1.0)
        if connected_clients:
            down_kbps = bandwidth_stats["in"] / 1024.0
            up_kbps = bandwidth_stats["out"] / 1024.0
            bandwidth_stats["in"] = 0
            bandwidth_stats["out"] = 0
            payload = {"type": "stats", "down": round(down_kbps, 1), "up": round(up_kbps, 1)}
            msg = json.dumps(payload)
            for client in connected_clients.copy():
                try:
                    await client.send(msg)
                except Exception:
                    pass

async def register(websocket):
    connected_clients.add(websocket)
    await send_lists_update()
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                action = data.get("action")
                input_val = data.get("ip")
                
                if action and input_val:
                    target_rule = input_val
                    if not any(c.isalpha() for c in input_val) and input_val in dns_cache:
                        target_rule = dns_cache[input_val]

                    target_ips = [target_rule] if not any(c.isalpha() for c in target_rule) else []
                    if any(c.isalpha() for c in target_rule):
                        try:
                            _, _, resolved = socket.gethostbyname_ex(target_rule)
                            target_ips.extend(resolved)
                        except socket.gaierror:
                            pass
                            
                    if not target_ips and not any(c.isalpha() for c in input_val):
                        target_ips = [input_val]

                    lists_changed = False

                    if action == "add_block":
                        if target_rule not in UI_BLACKLIST:
                            UI_BLACKLIST.append(target_rule)
                            lists_changed = True
                        if target_rule in UI_WHITELIST:
                            UI_WHITELIST.remove(target_rule)
                            lists_changed = True
                        for ip in target_ips:
                            pending_suspects.discard(ip)
                            if ip in WHITELIST_IPS:
                                WHITELIST_IPS.remove(ip)
                            if ip not in BLOCKLIST_SUBNETS:
                                BLOCKLIST_SUBNETS.append(ip)
                                os.system(f"iptables -A OUTPUT -d {ip} -j DROP")
                                os.system(f"iptables -A INPUT -s {ip} -j DROP")

                    elif action == "remove_block":
                        if target_rule in UI_BLACKLIST:
                            UI_BLACKLIST.remove(target_rule)
                            lists_changed = True
                        for ip in target_ips:
                            if ip in BLOCKLIST_SUBNETS:
                                BLOCKLIST_SUBNETS.remove(ip)
                                os.system(f"iptables -D OUTPUT -d {ip} -j DROP")
                                os.system(f"iptables -D INPUT -s {ip} -j DROP")

                    elif action == "add_whitelist":
                        if target_rule not in UI_WHITELIST:
                            UI_WHITELIST.append(target_rule)
                            lists_changed = True
                        if target_rule in UI_BLACKLIST:
                            UI_BLACKLIST.remove(target_rule)
                            lists_changed = True
                        for ip in target_ips:
                            pending_suspects.discard(ip)
                            if ip not in WHITELIST_IPS:
                                WHITELIST_IPS.append(ip)
                            if ip in BLOCKLIST_SUBNETS:
                                BLOCKLIST_SUBNETS.remove(ip)
                                os.system(f"iptables -D OUTPUT -d {ip} -j DROP")
                                os.system(f"iptables -D INPUT -s {ip} -j DROP")

                    elif action == "remove_whitelist":
                        if target_rule in UI_WHITELIST:
                            UI_WHITELIST.remove(target_rule)
                            lists_changed = True
                        for ip in target_ips:
                            if ip in WHITELIST_IPS:
                                WHITELIST_IPS.remove(ip)

                    if lists_changed:
                        await send_lists_update()
            except json.JSONDecodeError:
                pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.remove(websocket)

def is_blocked(ip):
    for subnet in BLOCKLIST_SUBNETS:
        if ip.startswith(subnet):
            return True
    return False

def is_local(ip):
    return ip.startswith(('192.168.', '10.', '127.', '172.16.', '172.31.', '169.254.'))

def process_packet(packet):
    global dns_cache, udp_throttle_cache, bandwidth_stats, traffic_monitor, pending_suspects
    if IP not in packet: return
    src_ip = packet[IP].src
    dst_ip = packet[IP].dst
    
    if is_local(dst_ip) and not is_local(src_ip):
        direction = "in"
        external_ip = src_ip
    elif is_local(src_ip) and not is_local(dst_ip):
        direction = "out"
        external_ip = dst_ip
    else: return 

    bandwidth_stats[direction] += len(packet)
    current_time = time.time()

    if direction == "in" and not is_whitelisted(external_ip) and external_ip not in pending_suspects:
        if external_ip not in traffic_monitor:
            traffic_monitor[external_ip] = []
        traffic_monitor[external_ip].append(current_time)
        traffic_monitor[external_ip] = [t for t in traffic_monitor[external_ip] if current_time - t < AUTOBAN_TIME_WINDOW]
        if not traffic_monitor[external_ip]:
            del traffic_monitor[external_ip]
        elif len(traffic_monitor[external_ip]) > AUTOBAN_THRESHOLD and not is_blocked(external_ip):
            pending_suspects.add(external_ip)
            domain_name = dns_cache.get(external_ip, "")
            payload = {"type": "suspect", "ip": external_ip, "domain": domain_name, "reason": "HIGH TRAFFIC VOLUME (FLOOD)"}
            if connected_clients and main_loop:
                msg = json.dumps(payload)
                for client in connected_clients.copy():
                    asyncio.run_coroutine_threadsafe(client.send(msg), main_loop)
            del traffic_monitor[external_ip]

    if is_blocked(external_ip): return

    if packet.haslayer(DNS) and packet.haslayer(DNSRR):
        try:
            if packet[DNS].qr == 1:
                qname = packet[DNS].qd.qname.decode('utf-8').rstrip('.')
                for i in range(packet[DNS].ancount):
                    rr = packet[DNS].an[i]
                    if rr.type == 1: dns_cache[rr.rdata] = qname
                if len(dns_cache) > 3000: dns_cache.clear()
        except Exception: pass
        return 

    port = None
    transport_layer = "TCP"

    if TCP in packet:
        transport_layer = "TCP"
        port = packet[TCP].sport if direction == "in" else packet[TCP].dport
    elif UDP in packet:
        transport_layer = "UDP"
        port = packet[UDP].sport if direction == "in" else packet[UDP].dport
        if current_time - udp_throttle_cache.get(external_ip, 0) < 1.5: return
        udp_throttle_cache[external_ip] = current_time
        if len(udp_throttle_cache) > 1000: udp_throttle_cache.clear()
    else: return

    if transport_layer == "UDP":
        protocol_name = "QUIC" if port == 443 else COMMON_PORTS.get(port, "UDP")
    else:
        protocol_name = COMMON_PORTS.get(port, "TCP")

    domain_name = dns_cache.get(external_ip, "")
    city, country, lat, lon = "Unknown", "Unknown", 0.0, 0.0

    if geo_reader:
        try:
            response = geo_reader.city(external_ip)
            if response.location.latitude is not None:
                lat = response.location.latitude
                lon = response.location.longitude
                city = response.city.name or "Unknown"
                country = response.country.name or "Unknown"
            else: return
        except Exception: return
    else:
        lat = random.uniform(-50, 65)
        lon = random.uniform(-140, 140)
        city, country = "Mock-City", "Mock-Country"

    payload = {
        "type": "packet", "ip": external_ip, "domain": domain_name,
        "city": city, "country": country, "lat": lat, "lon": lon,
        "direction": direction, "port": port, "protocol": protocol_name, "transport": transport_layer 
    }

    if connected_clients and main_loop:
        msg = json.dumps(payload)
        for client in connected_clients.copy():
            asyncio.run_coroutine_threadsafe(client.send(msg), main_loop)

async def main():
    global main_loop
    main_loop = asyncio.get_running_loop()
    asyncio.create_task(broadcast_bandwidth())
    asyncio.create_task(lan_radar_loop()) 
    ws_server = await websockets.serve(register, "localhost", 8765)
    
    bpf_filter = "(tcp and (tcp[tcpflags] & tcp-syn != 0)) or udp"
    await main_loop.run_in_executor(None, lambda: sniff(filter=bpf_filter, prn=process_packet, store=0))
    await ws_server.wait_closed()

if __name__ == "__main__":
    try: asyncio.run(main())
    except PermissionError: print("\n[BŁĄD] Wymagane uprawnienia root! Uruchom przez sudo.")
    except KeyboardInterrupt: print("\n[*] Zamykanie systemu.")
EOF

# ==============================================================================
# GENEROWANIE PLIKU: index.html
# ==============================================================================
cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CYBERPUNK NETWORK UPLINK & FIREWALL</title>
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <style>
        * { box-sizing: border-box; }
        body { margin: 0; padding: 0; background-color: #030712; color: #22c55e; font-family: 'Courier New', Courier, monospace; display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
        #map-container { flex: 2; width: 100%; position: relative; }
        #map { width: 100%; height: 100%; background-color: #020617; border-bottom: 2px solid #1e293b; }
        
        #bandwidth-monitor { position: absolute; top: 20px; right: 20px; background: rgba(2, 6, 23, 0.85); border: 1px solid #1e293b; border-left: 3px solid #3b82f6; box-shadow: 0 0 15px rgba(59, 130, 246, 0.2); padding: 15px; z-index: 1000; pointer-events: none; color: #e2e8f0; width: 250px; }
        .bw-title { font-size: 11px; color: #94a3b8; letter-spacing: 2px; margin-bottom: 8px; border-bottom: 1px dashed #334155; padding-bottom: 4px; }
        .bw-row { display: flex; justify-content: space-between; align-items: baseline; margin-top: 5px; }
        .bw-label { color: #64748b; font-size: 12px; font-weight: bold; }
        .bw-unit { color: #475569; font-size: 11px; margin-left: 4px; }
        .bw-val-down { color: #22c55e; font-size: 16px; font-weight: bold; text-shadow: 0 0 8px rgba(34, 197, 94, 0.6); }
        .bw-val-up { color: #3b82f6; font-size: 16px; font-weight: bold; text-shadow: 0 0 8px rgba(59, 130, 246, 0.6); }

        #rules-panel { position: absolute; top: 125px; right: 20px; background: rgba(15, 15, 20, 0.85); border: 1px solid #334155; border-right: 3px solid #64748b; box-shadow: 0 0 15px rgba(0, 0, 0, 0.5); padding: 15px; z-index: 1000; pointer-events: auto; color: #e2e8f0; width: 250px; max-height: calc(100% - 145px); overflow-y: auto; }
        .rules-title { font-size: 11px; color: #94a3b8; letter-spacing: 2px; font-weight: bold; margin-bottom: 10px; border-bottom: 1px dashed #334155; padding-bottom: 4px; }
        .rule-section { margin-bottom: 15px; }
        .rule-sub { font-size: 10px; font-weight: bold; margin-bottom: 5px; }
        .rule-sub-bl { color: #ef4444; }
        .rule-sub-wl { color: #22c55e; }
        .rule-item { display: flex; justify-content: space-between; align-items: center; font-size: 11px; padding: 4px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .rule-ip { font-family: 'Courier New', Courier, monospace; word-break: break-all; margin-right: 5px; }
        .rule-del { cursor: pointer; color: #64748b; font-weight: bold; transition: 0.2s; white-space: nowrap; }
        .rule-del:hover { color: #ef4444; }

        #recent-panel { position: absolute; bottom: 20px; left: 20px; background: rgba(6, 18, 36, 0.85); border: 1px solid #3b82f6; border-left: 3px solid #3b82f6; box-shadow: 0 0 15px rgba(59, 130, 246, 0.2); padding: 15px; z-index: 1000; pointer-events: auto; color: #e2e8f0; width: 330px; max-height: 45%; overflow-y: auto; }
        .r-title { font-size: 11px; color: #60a5fa; letter-spacing: 2px; font-weight: bold; margin-bottom: 10px; border-bottom: 1px dashed #3b82f6; padding-bottom: 4px; }
        .r-entry { display: flex; justify-content: space-between; align-items: center; font-size: 11px; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .r-info { display: flex; flex-direction: column; width: 70%; }
        .r-ip { font-family: 'Courier New', Courier, monospace; color: #93c5fd; font-weight: bold; }
        .r-domain { color: #64748b; font-style: italic; font-size: 9px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 2px;}

        #threat-panel { position: absolute; top: 20px; left: 20px; background: rgba(15, 10, 2, 0.85); border: 1px solid #fbbf24; border-right: 3px solid #fbbf24; box-shadow: 0 0 15px rgba(251, 191, 36, 0.3); padding: 15px; z-index: 1001; pointer-events: auto; color: #e2e8f0; width: 330px; max-height: 45%; overflow-y: auto; display: none; }
        .q-title { font-size: 11px; color: #fbbf24; letter-spacing: 2px; font-weight: bold; margin-bottom: 10px; border-bottom: 1px dashed #fbbf24; padding-bottom: 4px; }
        .q-entry { margin-bottom: 12px; font-size: 11px; line-height: 1.4; border-left: 2px solid #fbbf24; padding-left: 8px; background-color: rgba(255, 255, 255, 0.02); padding-top: 4px; padding-bottom: 4px; }
        .q-ip { color: #fbbf24; font-weight: bold; font-size: 13px; }
        .q-domain { color: #fde68a; font-style: italic; }
        .q-reason { color: #94a3b8; font-size: 10px; display: block; margin-top: 2px; margin-bottom: 6px; }

        #lan-panel { position: absolute; top: 20px; left: 50%; transform: translateX(-50%); background: rgba(4, 20, 10, 0.85); border: 1px solid #22c55e; border-top: 3px solid #22c55e; box-shadow: 0 0 15px rgba(34, 197, 94, 0.2); padding: 15px; z-index: 1000; pointer-events: auto; color: #e2e8f0; width: 350px; max-height: 35%; overflow-y: auto; }
        .lan-title { font-size: 11px; color: #86efac; letter-spacing: 2px; font-weight: bold; margin-bottom: 10px; border-bottom: 1px dashed #22c55e; padding-bottom: 4px; text-align: center; }
        .lan-subnet { color: #22c55e; font-family: 'Courier New', Courier, monospace; font-size: 10px; margin-bottom: 8px; text-align: center; }
        .lan-entry { display: flex; flex-direction: column; font-size: 11px; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
        .lan-info-top, .lan-info-bottom { display: flex; justify-content: space-between; align-items: baseline; }
        .lan-ip { color: #ffffff; font-weight: bold; }
        .lan-os { color: #fbbf24; font-size: 9px; font-weight: bold; }
        .lan-mac { color: #64748b; font-family: 'Courier New', Courier, monospace; font-size: 10px; }
        .lan-host { color: #93c5fd; font-style: italic; font-size: 10px; max-width: 60%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-align: right;}

        .btn-action { background: transparent; border: 1px solid #334155; color: #94a3b8; font-family: 'Courier New', Courier, monospace; font-size: 10px; cursor: pointer; padding: 4px 8px; transition: all 0.2s ease-in-out; margin-right: 5px; }
        .btn-block:hover { background: #ef4444; color: #fff; border-color: #ef4444; box-shadow: 0 0 8px rgba(239, 68, 68, 0.8); }
        .btn-allow:hover { background: #22c55e; color: #fff; border-color: #22c55e; box-shadow: 0 0 8px rgba(34, 197, 94, 0.8); }

        #terminal { flex: 1; padding: 15px; overflow-y: auto; font-size: 13px; background-color: #000000; border-top: 1px solid #1e293b; box-shadow: inset 0 0 20px rgba(0, 0, 0, 1); padding-bottom: 40px; }
        #command-line { position: fixed; bottom: 0; left: 0; width: 100%; display: flex; padding: 10px 15px; background-color: #050505; border-top: 1px dashed #ef4444; align-items: center; }
        .prompt { color: #ef4444; font-weight: bold; margin-right: 10px; }
        #cmd-input { flex: 1; background: transparent; border: none; color: #ffffff; font-family: 'Courier New', Courier, monospace; font-size: 13px; outline: none; }
        #cmd-input::placeholder { color: #334155; }
        .log-entry { margin-bottom: 5px; line-height: 1.4; }
        .log-time { color: #64748b; }
        .log-status { color: #22c55e; }
        .log-ip { color: #3b82f6; font-weight: bold; }
        .log-geo { color: #a855f7; }
        .log-proto-tcp { color: #fbbf24; font-weight: bold; } 
        .log-proto-udp { color: #a855f7; font-weight: bold; } 
        .log-domain { color: #f472b6; font-style: italic; } 
        .leaflet-control-container { display: none; }
    </style>
</head>
<body>
    <div id="map-container">
        <div id="map"></div>
        <div id="bandwidth-monitor">
            <div class="bw-title">NETWORK MATRIX</div>
            <div class="bw-row"><span class="bw-label">DWN:</span><div><span id="stat-down" class="bw-val-down">0.0</span> <span class="bw-unit">KB/s</span></div></div>
            <div class="bw-row"><span class="bw-label">UPL:</span><div><span id="stat-up" class="bw-val-up">0.0</span> <span class="bw-unit">KB/s</span></div></div>
        </div>
        <div id="rules-panel">
            <div class="rules-title">FIREWALL DATABANKS</div>
            <div class="rule-section">
                <div class="rule-sub rule-sub-bl">BLACKLIST <span id="bl-count">(0)</span></div>
                <div id="blacklist-container"></div>
            </div>
            <div class="rule-section">
                <div class="rule-sub rule-sub-wl">WHITELIST <span id="wl-count">(0)</span></div>
                <div id="whitelist-container"></div>
            </div>
        </div>
        <div id="threat-panel">
            <div class="q-title">THREAT ASSESSMENT PENDING</div>
            <div id="threat-list"></div>
        </div>
        <div id="recent-panel">
            <div class="r-title">ACTIVE UPLINKS (UNIQUE)</div>
            <div id="recent-list"></div>
        </div>
        <div id="lan-panel">
            <div class="lan-title">LAN TOPOLOGY RADAR</div>
            <div class="lan-subnet" id="lan-subnet-text">SUBNET: SCANNING...</div>
            <div id="lan-list"></div>
        </div>
    </div>
    
    <div id="terminal"></div>
    <div id="command-line">
        <span class="prompt">root@firewall:~#</span>
        <input type="text" id="cmd-input" placeholder="Wpisz IP lub domenę aby zablokować, lub 'allow DOMENA' aby dodać do białej listy..." autocomplete="off" />
    </div>

    <script>
        const map = L.map('map', { preferCanvas: true, minZoom: 2, maxZoom: 10 }).setView([35, 0], 2);
        L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}{r}.png', { attribution: '&copy; CartoDB' }).addTo(map);

        const HOME_COORD = [52.2297, 21.0122]; 
        const terminal = document.getElementById('terminal');
        const statDown = document.getElementById('stat-down');
        const statUp = document.getElementById('stat-up');
        const threatPanel = document.getElementById('threat-panel');
        const threatList = document.getElementById('threat-list');
        const recentListContainer = document.getElementById('recent-list');
        const lanSubnetText = document.getElementById('lan-subnet-text');
        const lanListContainer = document.getElementById('lan-list');

        const recentConnections = [];
        const MAX_RECENT = 8;

        function updateRecentConnections(ip, domain, protocol) {
            const existingIdx = recentConnections.findIndex(c => c.ip === ip);
            if (existingIdx !== -1) recentConnections.splice(existingIdx, 1);
            recentConnections.unshift({ ip, domain, protocol });
            if (recentConnections.length > MAX_RECENT) recentConnections.pop();
            renderRecentConnections();
        }

        function renderRecentConnections() {
            recentListContainer.innerHTML = '';
            recentConnections.forEach(conn => {
                const domainStr = conn.domain ? `(${conn.domain})` : 'Nieznana domena';
                const targetName = conn.domain ? conn.domain : conn.ip;
                recentListContainer.innerHTML += `
                    <div class="r-entry">
                        <div class="r-info">
                            <span class="r-ip">${conn.ip}</span>
                            <span class="r-domain">${domainStr}</span>
                        </div>
                        <button class="btn-action btn-block" style="margin:0;" onclick="blockRecent('${conn.ip}', '${targetName}')">[ BLOCK ]</button>
                    </div>
                `;
            });
        }

        window.blockRecent = function(ip, targetName) {
            ws.send(JSON.stringify({ action: "add_block", ip: ip }));
            appendSystemLog(`<span style="color: #ef4444; font-weight: bold;">[COMMAND]</span> &gt; MANUAL BLOCK APPLIED TO: <span class="log-ip" style="color: #ef4444;">${targetName}</span>`);
            const existingIdx = recentConnections.findIndex(c => c.ip === ip);
            if (existingIdx !== -1) {
                recentConnections.splice(existingIdx, 1);
                renderRecentConnections();
            }
        };

        function formatLogTime() { return new Date().toTimeString().split(' ')[0]; }

        function appendSystemLog(message) {
            const logHtml = `<div class="log-entry"><span class="log-time">[${formatLogTime()}]</span> ${message}</div>`;
            terminal.insertAdjacentHTML('beforeend', logHtml);
            terminal.scrollTop = terminal.scrollHeight;
        }

        appendSystemLog(`<span class="log-status" style="color: #64748b;">SYSTEM INITIALIZATION... FIREWALL DATABANKS LOADED.</span>`);

        function animateProjectile(startCoord, endCoord, color, durationMs = 700) {
            const startTime = performance.now();
            const trail = L.polyline([startCoord, startCoord], { color: color, weight: 1.5, opacity: 0.35, dashArray: '4, 4' }).addTo(map);
            const projectile = L.circleMarker(startCoord, { radius: 2, color: '#ffffff', fillColor: color, fillOpacity: 1, weight: 1 }).addTo(map);

            function frame(currentTime) {
                const elapsed = currentTime - startTime;
                const progress = Math.min(elapsed / durationMs, 1);
                const easeProgress = 1 - Math.pow(1 - progress, 3);
                const currentPos = [
                    startCoord[0] + (endCoord[0] - startCoord[0]) * easeProgress,
                    startCoord[1] + (endCoord[1] - startCoord[1]) * easeProgress
                ];

                projectile.setLatLng(currentPos);
                trail.setLatLngs([startCoord, currentPos]);

                if (progress < 1) {
                    requestAnimationFrame(frame);
                } else {
                    map.removeLayer(projectile);
                    const impactRing = L.circleMarker(endCoord, { radius: 4, color: color, fillColor: 'transparent', weight: 1.5, opacity: 0.8 }).addTo(map);
                    setTimeout(() => { map.removeLayer(impactRing); map.removeLayer(trail); }, 300);
                }
            }
            requestAnimationFrame(frame);
        }

        const ws = new WebSocket("ws://localhost:8765");

        ws.onopen = () => { appendSystemLog(`<span class="log-status">WEBSOCKET ESTABLISHED</span>`); };
        ws.onerror = () => { appendSystemLog(`<span style="color:red">ERROR: Upewnij się, że server.py działa.</span>`); };

        window.decideThreat = function(ip, domain, decision) {
            const elementId = `s-${ip.replace(/\\./g, '-')}`;
            const targetName = domain ? domain : ip;
            if (decision === 'block') {
                ws.send(JSON.stringify({ action: "add_block", ip: ip }));
                appendSystemLog(`<span style="color: #ef4444; font-weight: bold;">[COMMAND]</span> &gt; THREAT ELIMINATED: <span class="log-ip" style="color: #ef4444;">${targetName}</span>`);
            } else if (decision === 'allow') {
                ws.send(JSON.stringify({ action: "add_whitelist", ip: ip }));
                appendSystemLog(`<span style="color: #22c55e; font-weight: bold;">[COMMAND]</span> &gt; ACCESS GRANTED (WHITELIST): <span class="log-ip" style="color: #22c55e;">${targetName}</span>`);
            }
            const entryToRemove = document.getElementById(elementId);
            if (entryToRemove) entryToRemove.remove();
            if (threatList.children.length === 0) threatPanel.style.display = "none";
        };

        window.removeRule = function(ip, type) {
            if (type === 'block') {
                ws.send(JSON.stringify({ action: "remove_block", ip: ip }));
                appendSystemLog(`<span style="color: #22c55e; font-weight: bold;">[FIREWALL]</span> &gt; RULE REMOVED (UNBLOCKED): <span class="log-ip">${ip}</span>`);
            } else {
                ws.send(JSON.stringify({ action: "remove_whitelist", ip: ip }));
                appendSystemLog(`<span style="color: #fbbf24; font-weight: bold;">[FIREWALL]</span> &gt; RULE REMOVED (UN-WHITELISTED): <span class="log-ip">${ip}</span>`);
            }
        };

        ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            
            if (data.type === "stats") {
                statDown.innerText = data.down.toFixed(1);
                statUp.innerText = data.up.toFixed(1);
                return; 
            }

            if (data.type === "lists") {
                const blContainer = document.getElementById('blacklist-container');
                const wlContainer = document.getElementById('whitelist-container');
                
                document.getElementById('bl-count').innerText = `(${data.blacklist.length})`;
                document.getElementById('wl-count').innerText = `(${data.whitelist.length})`;

                blContainer.innerHTML = '';
                data.blacklist.forEach(rule => {
                    blContainer.innerHTML += `
                        <div class="rule-item">
                            <span class="rule-ip" style="color:#fca5a5;">${rule}</span>
                            <span class="rule-del" onclick="removeRule('${rule}', 'block')">[ X ]</span>
                        </div>
                    `;
                });

                wlContainer.innerHTML = '';
                data.whitelist.forEach(rule => {
                    wlContainer.innerHTML += `
                        <div class="rule-item">
                            <span class="rule-ip" style="color:#86efac;">${rule}</span>
                            <span class="rule-del" onclick="removeRule('${rule}', 'whitelist')">[ X ]</span>
                        </div>
                    `;
                });
                return;
            }

            if (data.type === "lan_scan") {
                lanSubnetText.innerText = `SUBNET: ${data.subnet} | NODES: ${data.devices.length}`;
                lanListContainer.innerHTML = '';
                if (data.devices.length === 0) {
                    lanListContainer.innerHTML = '<div style="text-align:center; font-size:10px; color:#64748b; margin-top:10px;">NO DEVICES FOUND</div>';
                } else {
                    data.devices.forEach(device => {
                        lanListContainer.innerHTML += `
                            <div class="lan-entry">
                                <div class="lan-info-top">
                                    <span class="lan-ip">${device.ip}</span>
                                    <span class="lan-os">[${device.os}]</span>
                                </div>
                                <div class="lan-info-bottom">
                                    <span class="lan-mac">${device.mac.toUpperCase()}</span>
                                    <span class="lan-host">${device.hostname}</span>
                                </div>
                            </div>
                        `;
                    });
                }
                return;
            }

            if (data.type === "suspect") {
                const elementId = `s-${data.ip.replace(/\\./g, '-')}`;
                if (document.getElementById(elementId)) return;
                threatPanel.style.display = "block";
                const domainText = data.domain ? `(${data.domain})` : "";
                const sHtml = `
                    <div class="q-entry" id="${elementId}">
                        <span class="q-ip">${data.ip}</span> <span class="q-domain">${domainText}</span>
                        <span class="q-reason">ALERT: ${data.reason}</span>
                        <div style="margin-top: 8px; display: flex;">
                            <button class="btn-action btn-block" onclick="decideThreat('${data.ip}', '${data.domain}', 'block')">[ BLACKLIST ]</button>
                            <button class="btn-action btn-allow" onclick="decideThreat('${data.ip}', '${data.domain}', 'allow')">[ WHITELIST ]</button>
                        </div>
                    </div>
                `;
                threatList.insertAdjacentHTML('afterbegin', sHtml); 
                appendSystemLog(`<span style="color: #fbbf24; font-weight: bold;">[SUSPECT DETECTED]</span> &gt; AWAITING ORDERS: <span class="log-ip" style="color: #fbbf24;">${data.ip}</span>`);
                return;
            }
            
            if (data.type === "packet") {
                updateRecentConnections(data.ip, data.domain, data.protocol);

                const targetCoord = [data.lat, data.lon];
                const locText = (data.city !== "Unknown" && data.country !== "Unknown") ? `${data.city}, ${data.country}` : data.country;
                const protoClass = data.transport === "UDP" ? "log-proto-udp" : "log-proto-tcp";
                const protoTag = data.port ? `<span class="${protoClass}">[${data.protocol}/${data.port}]</span>` : "";
                const domainTag = data.domain ? ` <span class="log-domain">(${data.domain})</span>` : "";

                appendSystemLog(`
                    <span class="log-status">UPLINK ESTABLISHED</span> &gt; 
                    IP: <span class="log-ip">${data.ip}</span>${domainTag} ${protoTag} 
                    <span class="log-status">TARGET:</span> <span class="log-geo">&lt;${locText}&gt;</span>
                `);

                let startPoint, endPoint, projectileColor;
                if (data.transport === "UDP") {
                    startPoint = data.direction === "in" ? targetCoord : HOME_COORD;
                    endPoint = data.direction === "in" ? HOME_COORD : targetCoord;
                    projectileColor = '#a855f7'; 
                } else if (data.direction === "in") {
                    startPoint = targetCoord; endPoint = HOME_COORD; projectileColor = '#22c55e'; 
                } else {
                    startPoint = HOME_COORD; endPoint = targetCoord; projectileColor = '#3b82f6'; 
                }

                animateProjectile(startPoint, endPoint, projectileColor, 750);
            }
        };

        const cmdInput = document.getElementById('cmd-input');
        cmdInput.addEventListener('keypress', function(e) {
            if (e.key === 'Enter') {
                const inputValue = this.value.trim();
                if (inputValue && ws.readyState === WebSocket.OPEN) {
                    if (inputValue.startsWith("allow ")) {
                        const targetValue = inputValue.replace("allow ", "").trim();
                        if (targetValue) {
                            ws.send(JSON.stringify({ action: "add_whitelist", ip: targetValue }));
                            appendSystemLog(`<span style="color: #22c55e; font-weight: bold;">[COMMAND]</span> &gt; ACCESS GRANTED (WHITELIST): <span class="log-ip" style="color: #22c55e;">${targetValue}</span>`);
                        }
                    } else {
                        ws.send(JSON.stringify({ action: "add_block", ip: inputValue }));
                        appendSystemLog(`<span style="color: #ef4444; font-weight: bold;">[COMMAND]</span> &gt; THREAT ELIMINATED: <span class="log-ip" style="color: #ef4444;">${inputValue}</span>`);
                    }
                    this.value = '';
                }
            }
        });
    </script>
</body>
</html>
EOF

echo -e "\e[32m[+] Instalacja zakończona sukcesem! Skrypty wygenerowane i gotowe.\e[0m"
echo -e "\e[32m[+] Aby uruchomić centrum dowodzenia, po prostu wpisz w terminalu:\e[0m"
echo -e "\e[1;33m    bash ./run.sh\e[0m"
