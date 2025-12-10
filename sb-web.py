#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, json, base64, re, shlex, subprocess, urllib.request, urllib.parse
import yaml
import socket, psutil ,time, re
from flask import Flask, request, jsonify, render_template

# ====== 配置（可用 systemd Environment 覆盖） ======
HOST     = os.environ.get("SB_WEB_HOST", "0.0.0.0")
PORT     = int(os.environ.get("SB_WEB_PORT", "8088"))
TOKEN    = os.environ.get("SB_WEB_TOKEN", "changeme")

SB_START = os.environ.get("SB_START", "/opt/sing-box-web/sb-start.sh")
SB_STOP  = os.environ.get("SB_STOP",  "/opt/sing-box-web/sb-stop.sh")
SB_SVC   = os.environ.get("SB_SERVICE", "sing-box")
SB_CFG   = os.environ.get("SB_CFG", "/opt/sing-box-web/sing-box_config.json")
SB_BIN   = os.environ.get("SB_BIN", "/opt/sing-box-web/sing-box")

INJECT_RESOLVER_TAG = os.environ.get("SB_RESOLVER_TAG", "cn-dns")
INJECT_IFACE        = os.environ.get("SB_IFACE", "eth0")

# 多路复用配置
ENABLE_MULTIPLEX = os.environ.get("SB_ENABLE_MULTIPLEX", "true").lower() in ("true", "1", "yes")
MULTIPLEX_PROTOCOL = os.environ.get("SB_MULTIPLEX_PROTOCOL", "smux")  # smux 或 h2mux
MULTIPLEX_MAX_CONN = int(os.environ.get("SB_MULTIPLEX_MAX_CONN", "4"))
MULTIPLEX_MIN_STREAMS = int(os.environ.get("SB_MULTIPLEX_MIN_STREAMS", "4"))
MULTIPLEX_MAX_STREAMS = int(os.environ.get("SB_MULTIPLEX_MAX_STREAMS", "0"))

STATE_FILE = "/opt/sing-box-web/sb-web-state.json"   # {"sub_url":"...","last_node_tag":"..."}
NODES_FILE = "/opt/sing-box-web/sb-web-nodes.json"   # {"nodes":[ ...sing-box outbounds... ]}

app = Flask(__name__, template_folder="templates", static_folder="static")

# ====== 工具 ======
def ok(msg="", **kw): d={"ok":True,"msg":msg}; d.update(kw); return jsonify(d)
def err(msg="", **kw): d={"ok":False,"msg":msg}; d.update(kw); return jsonify(d), 400
def authed(): return TOKEN and request.headers.get("X-Token","")==TOKEN

def get_default_interface():
    # 获取所有网卡信息
    stats = psutil.net_if_stats()
    # 排除 lo (回环) 和 docker 等虚拟网卡
    # 简单粗暴的策略：找一个状态是 UP 且不是 lo 的网卡
    # 更好的策略：查询默认路由走的网卡
    
    # 方案 A: 使用 psutil 简单查找
    for interface, stat in stats.items():
        if interface != 'lo' and stat.isup:
            return interface
            
    # 方案 B (更准): 通过连接外网来确定出口网卡
    # 这是一个比较通用的 hack 方法
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        # 根据 IP 反查网卡名
        addrs = psutil.net_if_addrs()
        for interface, snics in addrs.items():
            for snic in snics:
                if snic.address == ip:
                    return interface
    except:
        pass
        
    return "eth0" # 实在找不到就回退到 eth0

default_iface = get_default_interface() # 获取到 ens33

# 修改 config 字典
outbound_config = {
    "type": "direct",
    "tag": "direct",
    "bind_interface": default_iface  # <--- 这里使用变量
}


def run(cmd:str, timeout=60):
    try:
        p=subprocess.run(shlex.split(cmd), capture_output=True, text=True, timeout=timeout)
        return p.returncode==0, (p.stdout or ""), (p.stderr or "")
    except Exception as e:
        return False, "", str(e)

def http_get(url, timeout=25):
    req=urllib.request.Request(url, headers={"User-Agent":"curl/7.88"})
    with urllib.request.urlopen(req, timeout=timeout) as r: return r.read()

def b64maybe(buf:bytes)->str:
    try: return base64.b64decode(buf + b"==", validate=False).decode("utf-8","ignore")
    except Exception: return buf.decode("utf-8","ignore")

def state_load():
    try: return json.load(open(STATE_FILE))
    except Exception: return {}
def state_save(obj:dict):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp=STATE_FILE+".tmp"; open(tmp,"w").write(json.dumps(obj,ensure_ascii=False,indent=2)); os.replace(tmp,STATE_FILE)
def nodes_load():
    try: return json.load(open(NODES_FILE)).get("nodes",[])
    except Exception: return []
def nodes_save(nodes:list):
    os.makedirs(os.path.dirname(NODES_FILE), exist_ok=True)
    tmp=NODES_FILE+".tmp"; open(tmp,"w").write(json.dumps({"nodes":nodes},ensure_ascii=False,indent=2)); os.replace(tmp,NODES_FILE)

def get_multiplex_config():
    """返回多路复用配置"""
    if not ENABLE_MULTIPLEX:
        return None
    return {
        "enabled": True,
        "protocol": MULTIPLEX_PROTOCOL,
        "max_connections": MULTIPLEX_MAX_CONN,
        "min_streams": MULTIPLEX_MIN_STREAMS,
        "max_streams": MULTIPLEX_MAX_STREAMS
    }

# ====== 解析订阅（v2rayN + Clash YAML） ======
def normalize_tag(t, used:set):
    t=re.sub(r"[^A-Za-z0-9_.:-]+","_", t or "node").strip("_")[:48]
    if t in used:
        i=2
        while f"{t}-{i}" in used: i+=1
        t=f"{t}-{i}"
    used.add(t); return t

def inject(ob:dict):
    if INJECT_RESOLVER_TAG: ob["domain_resolver"]={"server":INJECT_RESOLVER_TAG,"strategy":"ipv4_only"}
    if INJECT_IFACE:        ob["bind_interface"]=INJECT_IFACE
    ob.setdefault("domain_strategy","ipv4_only")
    return ob

def parse_vmess(line: str):
    try: js=json.loads(base64.b64decode(line[8:]+"==").decode("utf-8","ignore"))
    except Exception: return None
    add=js.get("add") or js.get("address"); port=int(js.get("port",443) or 443)
    uuid=js.get("id") or js.get("uuid"); host=js.get("host") or js.get("sni") or add
    path=js.get("path") or "/"; net=js.get("net") or "ws"; sni=js.get("sni") or host
    if not path.startswith("/"): path="/"+path
    ob={"type":"vmess","tag":js.get("ps") or f"{add}:{port}","server":add,"server_port":port,"uuid":uuid,"security":"auto",
        "tls":{"enabled": True,"server_name":sni,"insecure":True,"alpn":["http/1.1"],"utls":{"enabled":True,"fingerprint":"chrome"}},
        "transport":{"type":net or "ws","path":path,"headers":{"Host":host} if host else None,"max_early_data":0}}
    
    # 添加多路复用
    mux = get_multiplex_config()
    if mux:
        ob["multiplex"] = mux
    
    return inject(ob)

def parse_vless(line: str):
    u = urllib.parse.urlparse(line)
    if u.scheme != "vless":
        return None
    uuid = u.username
    host = u.hostname
    port = u.port or 443
    q = urllib.parse.parse_qs(u.query)

    # 基本参数
    sni   = q.get("sni", [host])[0]
    h2    = q.get("host", [host])[0]
    path  = q.get("path", ["/"])[0]
    net   = (q.get("type", ["tcp"])[0] or "tcp").lower()
    flow  = q.get("flow", [None])[0]               # 兼容 xtls-rprx-vision
    fp    = (q.get("fp", ["chrome"])[0] or "chrome").lower()
    insecure = q.get("allowInsecure", ["0"])[0] in ("1","true","True","TRUE")
    alpn  = q.get("alpn", ["http/1.1"])
    if isinstance(alpn, str):
        alpn = [alpn]
    if not path.startswith("/"):
        path = "/" + path

    # Xray 的 fp=random 用 sing-box 的 randomized
    if fp == "random":
        fp = "randomized"

    security = (q.get("security", ["tls"])[0] or "tls").lower()

    # Reality：只保留公钥与短 ID（spider_x 在你的 sing-box 上不支持）
    pbk = q.get("pbk", [None])[0]                                   # public_key
    sid = q.get("sid", [None])[0] or q.get("short_id", [None])[0]   # short_id

    ob = {
        "type": "vless",
        "tag": urllib.parse.unquote(u.fragment) or f"{host}:{port}",
        "server": host,
        "server_port": port,
        "uuid": uuid,
        "flow": flow,
        "tls": {
            "enabled": True,
            "server_name": sni or host,
            "insecure": insecure,
            "alpn": alpn,
            "utls": {"enabled": True, "fingerprint": fp}
        },
        "domain_strategy": "ipv4_only"
    }

    # 传输层（ws/h2/grpc）
    if net in ("ws", "h2", "grpc"):
        ob["transport"] = {"type": net, "path": path, "max_early_data": 0}
        if net == "ws" and h2:
            ob["transport"]["headers"] = {"Host": h2}

    # Reality（security=reality）
    if security == "reality":
        ob["tls"]["reality"] = {"enabled": True}
        if pbk: ob["tls"]["reality"]["public_key"] = pbk
        if sid: ob["tls"]["reality"]["short_id"]  = sid

    return inject(ob)

def parse_hysteria2(line: str):
    # hysteria2://password@host:port?sni=xxx&alpn=h3&insecure=1#name
    u = urllib.parse.urlparse(line)
    if u.scheme not in ("hysteria2", "hy2"):
        return None
    pwd  = urllib.parse.unquote(u.username or "")
    host = u.hostname
    port = u.port or 443
    q    = urllib.parse.parse_qs(u.query)
    sni  = q.get("sni", [host])[0]
    alpn = q.get("alpn", ["h3"])
    if isinstance(alpn, str):
        alpn=[alpn]
    insecure = q.get("insecure", ["0"])[0] in ("1","true","True","TRUE")
    tag  = urllib.parse.unquote(u.fragment) or f"{host}:{port}"

    ob = {
        "type": "hysteria2",
        "tag": tag,
        "server": host,
        "server_port": port,
        "password": pwd,
        "tls": {
            "enabled": True,
            "server_name": sni or host,
            "insecure": insecure,
            "alpn": alpn
        },
        "domain_strategy": "ipv4_only"
    }
    return inject(ob)

def parse_tuic(line: str):
    # tuic://uuid:password@host:port?sni=xxx&alpn=h3&congestion_control=bbr#name
    u = urllib.parse.urlparse(line)
    if u.scheme != "tuic":
        return None
    creds = urllib.parse.unquote(u.username or "")
    if ":" in creds:
        uuid, pwd = creds.split(":", 1)
    else:
        uuid, pwd = creds, ""
    host = u.hostname
    port = u.port or 443
    q    = urllib.parse.parse_qs(u.query)
    sni  = q.get("sni", [host])[0]
    alpn = q.get("alpn", ["h3"])
    if isinstance(alpn, str):
        alpn=[alpn]
    cc   = q.get("congestion_control", ["bbr"])[0]
    tag  = urllib.parse.unquote(u.fragment) or f"{host}:{port}"

    ob = {
        "type": "tuic",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": uuid,
        "password": pwd,
        "congestion_control": cc,
        "tls": {
            "enabled": True,
            "server_name": sni or host,
            "alpn": alpn,
            "insecure": True
        },
        "domain_strategy": "ipv4_only"
    }
    return inject(ob)

def parse_trojan(line: str):
    u=urllib.parse.urlparse(line); 
    if u.scheme!="trojan": return None
    pwd=urllib.parse.unquote(u.username or ""); host=u.hostname; port=u.port or 443; q=urllib.parse.parse_qs(u.query)
    sni=q.get("sni",[host])[0]; alpn=q.get("alpn",["http/1.1"])[0]; fp=q.get("fp",["chrome"])[0]
    insecure=q.get("allowInsecure",["0"])[0] in ("1","true","True")
    ob={"type":"trojan","tag":urllib.parse.unquote(u.fragment) or f"{host}:{port}",
        "server":host,"server_port":port,"password":pwd,
        "tls":{"enabled":True,"server_name":sni,"insecure":insecure,"alpn":[alpn] if alpn else ["http/1.1"],
               "utls":{"enabled":True,"fingerprint":fp}}}
    
    # 添加多路复用
    mux = get_multiplex_config()
    if mux:
        ob["multiplex"] = mux
    
    tp=(q.get("type",["tcp"])[0] or "tcp").lower()
    if tp in ("ws","h2"):
        h=q.get("host",[sni or host])[0]; pth=q.get("path",["/"])[0]
        if not pth.startswith("/"): pth="/"+pth
        ob["transport"]={"type":tp,"path":pth}
        if tp=="ws" and h: ob["transport"]["headers"]={"Host":h}
        if tp=="h2" and "h2" not in ob["tls"]["alpn"]:
            ob["tls"]["alpn"]=["h2","http/1.1"]
    return inject(ob)

def parse_clash_yaml(text: str):
    try: data=yaml.safe_load(text)
    except Exception: return []
    proxies=data.get("proxies") or data.get("Proxy") or data.get("proxy") or []
    nodes, used = [], set()
    for p in proxies:
        try:
            typ=(p.get("type") or "").lower()
            name=normalize_tag(p.get("name") or f"{p.get('server')}:{p.get('port')}", used)
            srv=p.get("server"); prt=int(p.get("port") or 443)
            sni=p.get("sni") or p.get("servername") or srv
            alpn=p.get("alpn") or ["http/1.1"]
            fp=p.get("client-fingerprint") or p.get("fingerprint") or "chrome"
            insecure=bool(p.get("skip-cert-verify"))

            if typ=="vmess":
                ws=p.get("ws-opts") or {}
                path=(ws.get("path") or "/"); headers=ws.get("headers") or {}
                host=headers.get("Host") or headers.get("host") or p.get("servername") or srv
                if not path.startswith("/"): path="/"+path
                tls_enabled = bool(p.get("tls")) or bool(ws)
                ob={"type":"vmess","tag":name,"server":srv,"server_port":prt,"uuid":p.get("uuid"),
                    "security":"auto",
                    "tls":{"enabled":tls_enabled,"server_name":sni,"insecure":True,"alpn":alpn if isinstance(alpn,list) else [alpn],
                           "utls":{"enabled":True,"fingerprint":fp}},
                    "transport":{"type":"ws" if ws else "tcp","path":path,
                                 "headers":{"Host":host} if host and ws else None,"max_early_data":0}}
                
                # 添加多路复用
                mux = get_multiplex_config()
                if mux:
                    ob["multiplex"] = mux
                    
            elif typ=="vless":
                ws=p.get("ws-opts") or {}
                path=(ws.get("path") or "/"); headers=ws.get("headers") or {}
                host=headers.get("Host") or headers.get("host") or p.get("servername") or srv
                if not path.startswith("/"): path="/"+path
                ob={"type":"vless","tag":name,"server":srv,"server_port":prt,"uuid":p.get("uuid"),"flow":p.get("flow"),
                    "tls":{"enabled":True,"server_name":sni,"insecure":insecure,"alpn":alpn if isinstance(alpn,list) else [alpn],
                           "utls":{"enabled":True,"fingerprint":fp}},
                    "transport":{"type":"ws" if ws else "tcp","path":path,
                                 "headers":{"Host":host} if host and ws else None,"max_early_data":0}}
            elif typ=="trojan":
                ob={"type":"trojan","tag":name,"server":srv,"server_port":prt,"password":p.get("password"),
                    "tls":{"enabled":True,"server_name":sni,"insecure":insecure,"alpn":alpn if isinstance(alpn,list) else [alpn],
                           "utls":{"enabled":True,"fingerprint":fp}}}
                
                # 添加多路复用
                mux = get_multiplex_config()
                if mux:
                    ob["multiplex"] = mux
                
                if p.get("network")=="ws" or p.get("ws-opts"):
                    ws=p.get("ws-opts") or {}
                    path=(ws.get("path") or "/"); headers=ws.get("headers") or {}
                    host=headers.get("Host") or headers.get("host") or sni or srv
                    if not path.startswith("/"): path="/"+path
                    ob["transport"]={"type":"ws","path":path}
                    if host: ob["transport"]["headers"]={"Host":host}
                if p.get("network")=="h2" or p.get("h2-opts"):
                    h2=p.get("h2-opts") or {}
                    path=(h2.get("path") or "/")
                    if not path.startswith("/"): path="/"+path
                    ob["transport"]={"type":"h2","path":path}
                    if "h2" not in ob["tls"]["alpn"]: ob["tls"]["alpn"]=["h2","http/1.1"]
            elif typ == "hysteria2":
                pwd = p.get("password") or ""
                sni = p.get("sni") or p.get("servername") or srv
                alpn = p.get("alpn") or ["h3"]
                if isinstance(alpn, str): alpn=[alpn]
                ob = {
                    "type":"hysteria2","tag":name,
                    "server":srv,"server_port":prt,"password":pwd,
                    "tls":{"enabled":True,"server_name":sni,"insecure":insecure,"alpn":alpn},
                    "domain_strategy":"ipv4_only"
                }
                nodes.append(inject(ob)); continue

            elif typ == "tuic":
                uuid = p.get("uuid") or p.get("id") or ""
                pwd  = p.get("password") or ""
                sni = p.get("sni") or p.get("servername") or srv
                alpn = p.get("alpn") or ["h3"]
                if isinstance(alpn, str): alpn=[alpn]
                cc = p.get("congestion_control") or "bbr"
                ob = {
                    "type":"tuic","tag":name,
                    "server":srv,"server_port":prt,"uuid":uuid,"password":pwd,
                    "congestion_control": cc,
                    "tls":{"enabled":True,"server_name":sni,"insecure":True,"alpn":alpn},
                    "domain_strategy":"ipv4_only"
                }
                nodes.append(inject(ob)); continue
            else:
                continue
            nodes.append(inject(ob))
        except Exception:
            continue
    return nodes

def parse_subscription(url:str):
    raw=http_get(url); text=raw.decode("utf-8","ignore")
    # 明文
    if any(s in text for s in ("vmess://","vless://","trojan://","hysteria2://","hy2://","tuic://")):
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        out=[]
        for l in lines:
            if   l.startswith("vmess://"):    ob=parse_vmess(l)
            elif l.startswith("vless://"):    ob=parse_vless(l)
            elif l.startswith("trojan://"):   ob=parse_trojan(l)
            elif l.startswith("hysteria2://") or l.startswith("hy2://"): ob=parse_hysteria2(l)
            elif l.startswith("tuic://"):     ob=parse_tuic(l)
            else: ob=None
            if ob: out.append(ob)
        return out
    # base64
    d=b64maybe(raw)
    if any(s in d for s in ("vmess://","vless://","trojan://","hysteria2://","hy2://","tuic://")):
        out=[]
        for l in [x.strip() for x in d.splitlines() if x.strip()]:
            if   l.startswith("vmess://"):    ob=parse_vmess(l)
            elif l.startswith("vless://"):    ob=parse_vless(l)
            elif l.startswith("trojan://"):   ob=parse_trojan(l)
            elif l.startswith("hysteria2://") or l.startswith("hy2://"): ob=parse_hysteria2(l)
            elif l.startswith("tuic://"):     ob=parse_tuic(l)
            else: ob=None
            if ob: out.append(ob)
        return out
    # Clash YAML
    if ("proxies:" in text) or ("proxy-providers:" in text) or ("proxies:" in d) or ("proxy-providers:" in d):
        
        nodes=parse_clash_yaml(text)
        if not nodes: nodes=parse_clash_yaml(d)
        return nodes
    return []

# ====== 配置替换 ======
def replace_main_out(cfg:dict, node:dict) -> dict:
    found=False
    for i,ob in enumerate(cfg.get("outbounds",[])):
        if ob.get("tag")=="main-out":
            n2=json.loads(json.dumps(node)); n2["tag"]="main-out"
            cfg["outbounds"][i]=n2; found=True; break
    if not found:
        n2=json.loads(json.dumps(node)); n2["tag"]="main-out"
        cfg.setdefault("outbounds",[]).append(n2)
        cfg.setdefault("route",{}).setdefault("final","main-out")
    return cfg

# ====== 路由 ======
@app.route("/")
def index():
    return render_template("index.html", token=TOKEN, resolver=INJECT_RESOLVER_TAG, iface=INJECT_IFACE)

def must_auth():
    if not authed(): return False, err("Unauthorized")
    return True, None

@app.route("/api/init", methods=["POST"])
def api_init():
    ok_auth, resp = must_auth()
    if not ok_auth: return resp
    st = state_load()
    nodes = nodes_load()
    meta=[{"idx":i,"tag":n.get("tag"),"type":n.get("type"),
           "server":n.get("server"),"server_port":n.get("server_port")} for i,n in enumerate(nodes)]
    return ok("init", sub_url=st.get("sub_url",""), nodes=meta, last_tag=st.get("last_node_tag",""))

@app.route("/api/sub/fetch", methods=["POST"])
def api_sub_fetch():
    ok_auth, resp = must_auth()
    if not ok_auth: return resp
    data=request.get_json(force=True) or {}
    url=data.get("url","").strip()
    if not url:
        st=state_load(); url=st.get("sub_url","").strip()
    if not url: return err("缺少订阅 URL")
    try:
        nodes=parse_subscription(url)
        if not nodes: return err("未解析到任何节点（可能是受保护/Provider 订阅）")
        # 注入 resolver/iface
        for ob in nodes:
            if INJECT_RESOLVER_TAG: ob["domain_resolver"]={"server":INJECT_RESOLVER_TAG,"strategy":"ipv4_only"}
            if INJECT_IFACE:        ob["bind_interface"]=INJECT_IFACE
        # 保存 URL 与节点
        st=state_load(); st["sub_url"]=url; state_save(st)
        nodes_save(nodes)
        meta=[{"idx":i,"tag":n.get("tag"),"type":n.get("type"),
               "server":n.get("server"),"server_port":n.get("server_port")} for i,n in enumerate(nodes)]
        return ok(f"解析 {len(nodes)} 个节点", nodes=meta, last_tag=st.get("last_node_tag",""))
    except Exception as e:
        return err(f"拉取失败: {e}")

@app.route("/api/sub/apply", methods=["POST"])
def api_sub_apply():
    ok_auth, resp = must_auth()
    if not ok_auth: return resp
    data=request.get_json(force=True) or {}
    idx=int(data.get("index",-1))
    nodes = nodes_load()
    if idx<0 or idx>=len(nodes): return err("index 超界或未获取订阅")
    node=nodes[idx]
    # 再次注入
    if INJECT_RESOLVER_TAG: node["domain_resolver"]={"server":INJECT_RESOLVER_TAG,"strategy":"ipv4_only"}
    if INJECT_IFACE:        node["bind_interface"]=INJECT_IFACE
    # 替换 main-out
    cfg=json.load(open(SB_CFG))
    cfg2=replace_main_out(cfg, node)
    bak=f"{SB_CFG}.bak"; 
    try: os.replace(SB_CFG, bak)
    except Exception: pass
    with open(SB_CFG,"w") as f: json.dump(cfg2,f,ensure_ascii=False,indent=2)
    ok1, out1, err1 = run(f"{SB_BIN} check -c {SB_CFG}")
    if not ok1:
        if os.path.exists(bak): os.replace(bak, SB_CFG)
        return err("配置检查失败", stdout=out1, stderr=err1)
    ok2, out2, err2 = run(f"systemctl restart {SB_SVC}")
    # 记录 last_node_tag
    st=state_load(); st["last_node_tag"]=node.get("tag",""); state_save(st)
    return ok(f"已应用：{node.get('tag')}", stdout=out1+"\n"+out2, stderr=err1+"\n"+err2)

@app.route("/api/status", methods=["POST"])
def api_status():
    ok_auth, resp = must_auth()
    if not ok_auth: return resp
    ok1, out, err1 = run(f"systemctl status {SB_SVC} --no-pager --full")
    return ok("status", stdout=out, stderr=err1)

@app.route("/api/start", methods=["POST"])
def api_start():
    ok_auth, resp = must_auth()
    if not ok_auth: return resp
    ok1, out, err1 = run(SB_START)
    ok2, out2, _ = run(f"systemctl is-active {SB_SVC}")
    return ok("start", stdout=out, stderr=err1, svc=out2.strip())

@app.route("/api/stop", methods=["POST"])
def api_stop():
    ok_auth, resp = must_auth()
    if not ok_auth: return resp
    ok1, out, err1 = run(SB_STOP)
    ok2, out2, _ = run(f"systemctl is-active {SB_SVC}")
    return ok("stop", stdout=out, stderr=err1, svc=out2.strip())

@app.route("/api/config/mainout", methods=["POST"])
def api_cfg_mainout():
    if not (TOKEN and request.headers.get("X-Token","")==TOKEN):
        return jsonify(ok=False, msg="Unauthorized"), 401
    try:
        cfg = json.load(open(SB_CFG))
        ob = next((o for o in cfg.get("outbounds",[]) if o.get("tag")=="main-out"), None)
        if not ob:
            return jsonify(ok=True, msg="no main-out", node={})
        server = ob.get("server")
        port   = ob.get("server_port")
        tag    = ob.get("tag") or "main-out"
        typ    = ob.get("type")

        # 解析出 IPv4
        ip = server
        if isinstance(server, str) and server and not re.match(r'^\d{1,3}(\.\d{1,3}){3}$', server):
            try:
                infos = socket.getaddrinfo(server, port or 443, proto=socket.IPPROTO_TCP)
                v4 = [ai[4][0] for ai in infos if ':' not in ai[4][0]]
                ip = v4[0] if v4 else infos[0][4][0]
            except Exception:
                ip = None

        # 从状态里取"订阅别名"
        st = state_load()
        alias = st.get("last_node_tag", "")

        return jsonify(ok=True, msg="mainout",
                       node={"tag": tag, "alias": alias, "type": typ,
                             "server": server, "server_port": port, "ip": ip})
    except Exception as e:
        return jsonify(ok=False, msg=f"read cfg fail: {e}")
 
NET_IFACE = os.environ.get("SB_IFACE", "eth0")
_CPU_LAST = {"total": None, "idle": None, "ts": None}

# === 工具函数：CPU/温度/网卡字节 ===
def _read_cpu_times():
    # /proc/stat 第一行: cpu  user nice system idle iowait irq softirq steal guest guest_nice
    with open("/proc/stat","r") as f:
        line=f.readline()
    parts=line.split()
    if parts[0]!="cpu": return None,None
    nums=list(map(int, parts[1:]))
    idle=nums[3]+nums[4] if len(nums)>=5 else nums[3]  # idle + iowait
    total=sum(nums)
    return total,idle

def cpu_usage_percent():
    global _CPU_LAST
    total,idle=_read_cpu_times()
    if total is None: return None
    now=time.time()
    if _CPU_LAST["total"] is None:
        _CPU_LAST.update({"total":total,"idle":idle,"ts":now})
        return None
    dt_total=total-_CPU_LAST["total"]
    dt_idle =idle -_CPU_LAST["idle"]
    _CPU_LAST.update({"total":total,"idle":idle,"ts":now})
    if dt_total<=0: return None
    usage=100.0*(dt_total-dt_idle)/dt_total
    return round(usage,1)

def read_temperatures():
    temps=[]
    base="/sys/class/thermal"
    try:
        for z in os.listdir(base):
            if not z.startswith("thermal_zone"): continue
            tpath=os.path.join(base,z,"temp")
            typath=os.path.join(base,z,"type")
            try:
                t=float(open(tpath).read().strip())/1000.0
                tname=open(typath).read().strip()
                temps.append({"name":tname, "celsius": round(t,1)})
            except Exception:
                continue
    except Exception:
        pass
    return temps

def read_net_bytes(iface):
    try:
        rx=int(open(f"/sys/class/net/{iface}/statistics/rx_bytes").read().strip())
        tx=int(open(f"/sys/class/net/{iface}/statistics/tx_bytes").read().strip())
        return rx,tx
    except Exception:
        return None,None

# === 路由：/api/metrics ===
@app.route("/api/metrics", methods=["POST"])
def api_metrics():
    if not (TOKEN and request.headers.get("X-Token","")==TOKEN):
        return jsonify(ok=False, msg="Unauthorized"), 401
    try:
        cpu=cpu_usage_percent()
        temps=read_temperatures()
        rx,tx=read_net_bytes(NET_IFACE)
        return jsonify(ok=True, msg="metrics",
                       cpu={"usage": cpu},
                       temps=temps,
                       net={"iface": NET_IFACE, "rx_bytes": rx, "tx_bytes": tx, "ts": time.time()})
    except Exception as e:
        return jsonify(ok=False, msg=str(e)), 500
    
if __name__ == "__main__":
    app.run(host=HOST, port=PORT)