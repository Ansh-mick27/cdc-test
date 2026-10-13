"""Inline config, CSS and JS into one deployable index.html."""
import pathlib, sys

root = pathlib.Path(__file__).parent
url = sys.argv[1] if len(sys.argv) > 1 else 'PASTE_SUPABASE_URL_HERE'
key = sys.argv[2] if len(sys.argv) > 2 else 'PASTE_SUPABASE_KEY_HERE'
out = sys.argv[3] if len(sys.argv) > 3 else 'index.html'

css = (root / 'src/style.css').read_text()
parser = (root / 'src/parser.js').read_text()
app = (root / 'src/app.js').read_text()

html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src {url}; base-uri 'none'; form-action 'none'; object-src 'none'">
<meta name="referrer" content="no-referrer">
<title>CDC Online Test</title>
<style>
{css}
</style>
</head>
<body>
<div id="app"></div>
<noscript>Please enable JavaScript to take this test.</noscript>
<script>
/* ======== SETTINGS — edit these lines only ======== */
window.CT_CONFIG = {{
  supabaseUrl: "{url}",
  supabaseKey: "{key}",
  orgName: "CDC · Acropolis Institute",
  logoText: "CDC",
  defaultDomain: "",
  requireFullscreen: true
}};
/* ================================================== */
</script>
<script>
{parser}
</script>
<script>
{app}
</script>
</body>
</html>
"""
(root / out).write_text(html)
print('wrote', out, len(html), 'bytes')
