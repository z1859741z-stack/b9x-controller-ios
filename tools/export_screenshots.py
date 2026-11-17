#!/usr/bin/env python3
"""从 .xcresult 里导出 UI 测试的截图附件。

用法：python3 tools/export_screenshots.py <xxx.xcresult> <out-dir>
用 xcrun xcresulttool get 拿测试结果 JSON，找出所有 PNG 附件，
再用 xcresulttool export --type file --id 逐个导出。
失败时返回非零，调用方可用 simctl 截图兜底。
"""
import json
import subprocess
import sys
import os


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("cmd failed: %s\n%s" % (" ".join(cmd), r.stderr))
    return r.stdout


def collect_attachments(node, out):
    if isinstance(node, dict):
        if node.get("_type", {}).get("_name") == "ActionTestAttachment":
            name = node.get("filename", {}).get("_value", "attachment")
            uid = node.get("uuid", {}).get("_value")
            if uid and name.endswith(".png"):
                out.append((uid, name))
        for v in node.values():
            collect_attachments(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_attachments(v, out)


def main():
    xcresult, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    data = json.loads(run(["xcrun", "xcresulttool", "get",
                           "--path", xcresult, "--format", "json"]))
    atts = []
    collect_attachments(data, atts)
    print("found %d png attachments" % len(atts))
    seen = {}
    for uid, name in atts:
        # 同名附件只留最后一份（重跑的覆盖旧的）。
        seen[name] = uid
    for name, uid in sorted(seen.items()):
        dest = os.path.join(outdir, name if name.endswith(".png") else name + ".png")
        run(["xcrun", "xcresulttool", "export", "--type", "file",
             "--path", xcresult, "--output-path", dest, "--id", uid])
        print("exported", dest)
    if not seen:
        raise SystemExit("no png attachments found in %s" % xcresult)


if __name__ == "__main__":
    main()
