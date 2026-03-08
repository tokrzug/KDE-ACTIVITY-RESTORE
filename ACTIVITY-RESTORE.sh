#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="$HOME/.local/state"
DB="$STATE_DIR/activity-window-map.json"

PKG_DIR="$HOME/.local/share/kwin/scripts/activity_window_restore"
META="$PKG_DIR/metadata.json"
JS="$PKG_DIR/contents/code/main.js"

COLLECT_ID="activity_window_collector"
COLLECT_DIR="$HOME/.local/share/kwin/scripts/$COLLECT_ID"
COLLECT_META="$COLLECT_DIR/metadata.json"
COLLECT_JS="$COLLECT_DIR/contents/code/main.js"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$PKG_DIR/contents/code"
  [ -f "$DB" ] || printf '[]\n' > "$DB"
}

install_dependencies() {
  if need_cmd apt-get; then
    sudo apt-get update
    sudo apt-get install -y python3 qt6-tools-dev-tools kde-cli-tools kpackagetool6 || true
  elif need_cmd dnf; then
    sudo dnf install -y python3 qt6-qttools kde-cli-tools kf6-kpackage || true
  elif need_cmd pacman; then
    sudo pacman -Sy --noconfirm python qt6-tools kde-cli-tools kpackage5 || true
  elif need_cmd zypper; then
    sudo zypper install -y python3 qt6-tools kde-cli-tools kpackage || true
  else
    echo "No supported package manager found."
    exit 1
  fi

  echo "Check:";
  for x in qdbus6 python3 kpackagetool6 kwriteconfig6 journalctl; do
    if need_cmd "$x"; then echo " OK  $x"; else echo " MISS $x"; fi
  done
}

check_dependencies() {
  local miss=0
  for x in qdbus6 python3 kpackagetool6 kwriteconfig6 journalctl; do
    if ! need_cmd "$x"; then echo "Missing: $x"; miss=1; fi
  done
  [ "$miss" -eq 0 ]
}

write_metadata() {
  cat > "$META" <<'JSON'
{
  "KPlugin": {
    "Name": "Activity Window Restore",
    "Description": "Restore saved window activity assignments",
    "Icon": "preferences-system-windows",
    "Authors": [{ "Name": "OpenAI" }],
    "Id": "activity_window_restore",
    "Version": "1.0",
    "License": "GPL-3.0-or-later"
  },
  "X-Plasma-API": "javascript",
  "X-Plasma-MainScript": "code/main.js",
  "KPackageStructure": "KWin/Script"
}
JSON
}

generate_js() {
  python3 - "$DB" "$JS" <<'PY'
import json, pathlib, sys

db = pathlib.Path(sys.argv[1])
js_path = pathlib.Path(sys.argv[2])
rules = json.loads(db.read_text(encoding="utf-8"))

js = r'''
var RULES = __RULES__;
function s(v){ return String(v||""); }
function normTitle(t){
  t=s(t).toLowerCase().trim();
  t=t.replace(/\s*[—–-]\s*(mozilla firefox|firefox|google chrome|chrome|chromium|brave|konsole|opera)\s*$/i,"");
  t=t.replace(/\s+/g," ").trim();
  return t.substring(0,180);
}
function arrEq(a,b){ a=a||[]; b=b||[]; if(a.length!==b.length) return false; for(var i=0;i<a.length;i++) if(s(a[i])!==s(b[i])) return false; return true; }
function appKey(w){ return s(w.desktopFileName||w.resourceClass||"").toLowerCase(); }
function titleKey(w){ var a=appKey(w); if (/(firefox|chrome|chromium|brave|konsole|opera)/.test(a)) return normTitle(w.caption||""); return ""; }
function matches(w,r){
  if(!w||!w.normalWindow) return false;
  if(s(w.desktopFileName)!==s(r.desktopFile)) return false;
  if(s(w.resourceClass)!==s(r.resourceClass)) return false;
  if(s(w.resourceName)!==s(r.resourceName)) return false;
  if(s(w.windowRole)!==s(r.windowRole)) return false;
  if(titleKey(w)!==s(r.titleKey)) return false;
  return true;
}
function n(v,d){ var x=Number(v); return Number.isFinite(x)?x:d; }
function b(v){ return (v===true || v===1 || v==='1' || String(v).toLowerCase()==='true'); }
function applyGeom(w,r){
  try {
    if (b(r.fullscreen)) {
      if ('fullScreen' in w) w.fullScreen = true;
      return;
    }
    if ('fullScreen' in w) w.fullScreen = false;

    if (b(r.maximizeHorizontal) || b(r.maximizeVertical)) {
      if ('maximizeHorizontal' in w) w.maximizeHorizontal = b(r.maximizeHorizontal);
      if ('maximizeVertical' in w) w.maximizeVertical = b(r.maximizeVertical);
      return;
    }

    // Unmaximize before applying geometry.
    if ('maximizeHorizontal' in w) w.maximizeHorizontal = false;
    if ('maximizeVertical' in w) w.maximizeVertical = false;

    var g = w.frameGeometry;
    g.x = n(r.x, g.x);
    g.y = n(r.y, g.y);
    g.width = Math.max(120, n(r.width, g.width));
    g.height = Math.max(80, n(r.height, g.height));
    w.frameGeometry = g;
  } catch(e) {}
}
function applyRule(w){
  for(var i=0;i<RULES.length;i++){
    var r=RULES[i];
    if(matches(w,r)){
      var want=r.activities||[];
      var have=w.activities||[];
      if(!arrEq(have,want)) w.activities=want;
      applyGeom(w,r);
      return true;
    }
  }
  return false;
}
for (var i=0;i<workspace.stackingOrder.length;i++) applyRule(workspace.stackingOrder[i]);
workspace.windowAdded.connect(function(w){ setTimeout(function(){ applyRule(w); }, 150); });
'''
js_path.write_text(js.replace("__RULES__", json.dumps(rules, ensure_ascii=False)), encoding="utf-8")
PY
}

install_or_update_kwin_script() {
  ensure_dirs
  mkdir -p "$PKG_DIR/contents/code"
  write_metadata
  if ! kpackagetool6 --type=KWin/Script -u "$PKG_DIR" >/dev/null 2>&1; then
    kpackagetool6 --type=KWin/Script -i "$PKG_DIR" >/dev/null 2>&1 || {
      echo "KWin script install failed for path: $PKG_DIR" >&2
      return 1
    }
  fi
  kwriteconfig6 --file kwinrc --group Plugins --key activity_window_restoreEnabled true
  qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
}

append_from_info() {
  local info="$1"
  INFO_BLOB="$info" python3 - "$DB" <<'PY'
import json, os, pathlib, re, sys

db = pathlib.Path(sys.argv[1])
raw = os.environ.get("INFO_BLOB", "")

pairs={}
for line in raw.splitlines():
  m=re.match(r'^([^:]+):\s*(.*)$', line)
  if m: pairs[m.group(1).strip()] = m.group(2).strip()

def norm_title(t):
  t=(t or "").strip().lower()
  t=re.sub(r"\s*[—–-]\s*(mozilla firefox|firefox|google chrome|chrome|chromium|brave|konsole|opera)\s*$", "", t, flags=re.I)
  t=re.sub(r"\s+", " ", t).strip()
  return t[:180]

def parse_acts(v):
  vals=[]
  for x in re.split(r'[\s,]+', (v or '').strip()):
    if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', x):
      vals.append(x)
  return sorted(set(vals))

def parse_num(v, d=0):
  try:
    return int(float((v or '').strip()))
  except Exception:
    return d

def parse_bool(v):
  return str(v).strip().lower() in ('1','true','yes','on')
desktopFile = pairs.get('desktopFile','')
resourceClass = pairs.get('resourceClass','')
resourceName = pairs.get('resourceName','')
windowRole = pairs.get('role','') or pairs.get('windowRole','')
caption = pairs.get('caption','')
activities = parse_acts(pairs.get('activities',''))
x = parse_num(pairs.get('x','0'))
y = parse_num(pairs.get('y','0'))
width = parse_num(pairs.get('width','0'))
height = parse_num(pairs.get('height','0'))
maximizeHorizontal = parse_bool(pairs.get('maximizeHorizontal','0'))
maximizeVertical = parse_bool(pairs.get('maximizeVertical','0'))
fullscreen = parse_bool(pairs.get('fullscreen','0'))

if not (desktopFile or resourceClass or resourceName):
  raise SystemExit(2)
if not activities:
  raise SystemExit(2)

app=(desktopFile or resourceClass or '').lower()
titleKey = norm_title(caption) if re.search(r'(firefox|chrome|chromium|brave|konsole|opera)', app) else ''

entry={
  'desktopFile': desktopFile,
  'resourceClass': resourceClass,
  'resourceName': resourceName,
  'windowRole': windowRole,
  'titleKey': titleKey,
  'activities': activities,
  'x': x,
  'y': y,
  'width': width,
  'height': height,
  'maximizeHorizontal': maximizeHorizontal,
  'maximizeVertical': maximizeVertical,
  'fullscreen': fullscreen,
}

rows=json.loads(db.read_text(encoding='utf-8'))
for i,r in enumerate(rows):
  if all(r.get(k,'')==entry.get(k,'') for k in ('desktopFile','resourceClass','resourceName','windowRole','titleKey')):
    rows[i]=entry
    break
else:
  rows.append(entry)

db.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(entry, ensure_ascii=False))
PY
}

save_active() {
  local info
  info="$(qdbus6 org.kde.KWin /KWin org.kde.KWin.queryWindowInfo)"
  append_from_info "$info"
}

write_collect_script() {
  local out="$1"
  cat > "$out" <<'JS'
function s(v){ return String(v||""); }
function dumpAll(){
  print("__ACTCOLLECT__BEGIN");
  var ws = workspace.stackingOrder || [];
  for (var i=0;i<ws.length;i++) {
    var w = ws[i];
    if (!w || !w.normalWindow) continue;
    var o = {
      desktopFile: s(w.desktopFileName),
      resourceClass: s(w.resourceClass),
      resourceName: s(w.resourceName),
      role: s(w.windowRole),
      caption: s(w.caption),
      activities: (w.activities||[]).join(",")
    };
    print("__ACTCOLLECT__" + JSON.stringify(o));
  }
  print("__ACTCOLLECT__END");
}
dumpAll();
JS
}

save_all_via_kwin_collector() {
  local ts raw count dbg="$STATE_DIR/activity-window-collector-debug.log"
  local script_tmp="/tmp/list_windows_activities.$$.$RANDOM.js"
  local script_id=""
  : > "$dbg"

  cat > "$script_tmp" <<'JS'
function s(v){ return String(v||""); }
function wins(){
  if (typeof workspace.windowList === 'function') return workspace.windowList();
  if (workspace.stackingOrder) return workspace.stackingOrder;
  return [];
}
for (const w of wins()) {
  if (!w) continue;
  if (w.deleted) continue;
  if ((w.normalWindow === false) && (w.managed === false)) continue;
  const obj = {
    desktopFile: s(w.desktopFileName),
    resourceClass: s(w.resourceClass),
    resourceName: s(w.resourceName),
    role: s(w.windowRole),
    caption: s(w.caption),
    activities: (w.activities && w.activities.length) ? w.activities.join(',') : '',
    x: Number(w.x || 0),
    y: Number(w.y || 0),
    width: Number(w.width || 0),
    height: Number(w.height || 0),
    maximizeHorizontal: !!w.maximizeHorizontal,
    maximizeVertical: !!w.maximizeVertical,
    fullscreen: !!(w.fullScreen || w.fullscreen)
  };
  print('__ACTCOLLECT__' + JSON.stringify(obj));
}
JS

  ts="$(date --iso-8601=seconds)"
  script_id="$(dbus-send --session --print-reply --dest=org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript string:"$script_tmp" 2>>"$dbg" | awk '/uint32|int32/ {print $2; exit}')"
  if [ -z "${script_id:-}" ]; then
    echo "failed to load collector script" >> "$dbg"
    rm -f "$script_tmp"
    return 1
  fi

  qdbus6 org.kde.KWin "/Scripting/Script${script_id}" org.kde.kwin.Script.run >/dev/null 2>>"$dbg" || true
  sleep 1
  raw="$(journalctl --user --since "$ts" -o cat --no-pager 2>/dev/null | grep '__ACTCOLLECT__' || true)"
  qdbus6 org.kde.KWin "/Scripting/Script${script_id}" org.kde.kwin.Script.stop >/dev/null 2>>"$dbg" || true
  rm -f "$script_tmp"

  if [ -z "$raw" ]; then
    echo "no collector markers in journal since $ts" >> "$dbg"
    journalctl --user --since "$ts" -o cat --no-pager | tail -n 200 >> "$dbg" 2>/dev/null || true
    return 1
  fi

  count="$(RAW="$raw" python3 - "$DB" <<'PY'
import json, os, pathlib, re, sys

db=pathlib.Path(sys.argv[1])
raw=os.environ.get('RAW','')
rows=json.loads(db.read_text(encoding='utf-8'))
added=0

def norm_title(t):
  t=(t or '').strip().lower()
  t=re.sub(r"\s*[—–-]\s*(mozilla firefox|firefox|google chrome|chrome|chromium|brave|konsole|opera)\s*$", "", t, flags=re.I)
  t=re.sub(r"\s+", " ", t).strip()
  return t[:180]

for ln in raw.splitlines():
  if '__ACTCOLLECT__' not in ln:
    continue
  js=ln.split('__ACTCOLLECT__',1)[1].strip()
  try:
    o=json.loads(js)
  except Exception:
    continue
  desktopFile=o.get('desktopFile','')
  resourceClass=o.get('resourceClass','')
  resourceName=o.get('resourceName','')
  windowRole=o.get('role','')
  caption=o.get('caption','')
  activities=sorted({x for x in re.split(r'[\s,]+', o.get('activities','')) if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', x)})
  if not (desktopFile or resourceClass or resourceName) or not activities:
    continue
  app=(desktopFile or resourceClass or '').lower()
  titleKey = norm_title(caption) if re.search(r'(firefox|chrome|chromium|brave|konsole|opera)', app) else ''
  entry={
    'desktopFile':desktopFile,'resourceClass':resourceClass,'resourceName':resourceName,
    'windowRole':windowRole,'titleKey':titleKey,'activities':activities,
    'x': int(float(o.get('x',0) or 0)),
    'y': int(float(o.get('y',0) or 0)),
    'width': int(float(o.get('width',0) or 0)),
    'height': int(float(o.get('height',0) or 0)),
    'maximizeHorizontal': bool(o.get('maximizeHorizontal', False)),
    'maximizeVertical': bool(o.get('maximizeVertical', False)),
    'fullscreen': bool(o.get('fullscreen', False))
  }
  for i,r in enumerate(rows):
    if all(r.get(k,'')==entry.get(k,'') for k in ('desktopFile','resourceClass','resourceName','windowRole','titleKey')):
      rows[i]=entry
      break
  else:
    rows.append(entry)
  added += 1

db.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
print(added)
PY
)"

  [ "${count:-0}" -gt 0 ] || return 1
  echo "Saved rules from $count window(s) via KWin collector."
  return 0
}

restore_now() {
  local sid=""
  generate_js
  sid="$(dbus-send --session --print-reply --dest=org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript string:"$JS" 2>/dev/null | awk '/uint32|int32/ {print $2; exit}')"
  if [ -z "${sid:-}" ]; then
    echo "Restore failed: could not load KWin script via DBus."
    return 1
  fi
  qdbus6 org.kde.KWin "/Scripting/Script${sid}" org.kde.kwin.Script.run >/dev/null 2>&1 || true
  echo "Restore script executed via KWin DBus (Script${sid})."
}

save_now() {
  if save_all_via_kwin_collector; then
    :
  else
    echo "Collector could not enumerate all windows on this setup; saved active window only."
    echo "Debug: $STATE_DIR/activity-window-collector-debug.log"
    save_active || true
    echo "Tip: keep target window active and run Save multiple times for key apps."
  fi
  generate_js
  echo "Saved window activity rules. (Install/apply happens on Restore)"
}

guided_capture() {
  echo
  echo "Guided capture mode"
  echo "- Focus a target window"
  echo "- Press ENTER to save that active window"
  echo "- Type q then ENTER to finish"
  echo

  local ok=0 fail=0
  while true; do
    read -r -p "capture active window [ENTER/q]: " ans
    if [[ "${ans,,}" == "q" ]]; then
      break
    fi
    if save_active >/dev/null 2>&1; then
      ok=$((ok+1))
      echo "saved (#$ok)"
    else
      fail=$((fail+1))
      echo "skip/fail (#$fail)"
    fi
  done

  generate_js
  echo "Guided capture finished. saved=$ok failed=$fail"
  echo "Run option 1 (Restore) after restart to re-apply."
}

menu() {
  echo "1. Restore"
  echo "2. Save (tries all windows via KWin collector; fallback active window)"
  echo "3. Install dependencies"
  echo "4. Guided capture (manual window-by-window save)"
  printf "> "
  read -r choice

  case "$choice" in
    1)
      check_dependencies || { echo "Missing dependencies. Run 3."; exit 1; }
      ensure_dirs
      restore_now
      ;;
    2)
      check_dependencies || { echo "Missing dependencies. Run 3."; exit 1; }
      ensure_dirs
      save_now
      ;;
    3)
      install_dependencies
      ;;
    4)
      check_dependencies || { echo "Missing dependencies. Run 3."; exit 1; }
      ensure_dirs
      guided_capture
      ;;
    *)
      echo "Invalid option."
      exit 1
      ;;
  esac
}

menu
