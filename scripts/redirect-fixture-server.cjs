// Local, deterministic HTTP fixture for redirect and credential-leak checks on a device.
// Usage: node scripts/redirect-fixture-server.cjs [port]   (default 18770)
// On the device the app reaches it through: hdc rport tcp:18770 tcp:18770
// Every hit is recorded so a test can prove whether a redirect target was actually contacted
// and whether a credential header left the original origin.
const http = require('node:http');
const port = Number(process.argv[2] || 18770);
const hits = [];

function record(req, extra) {
  const headers = Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k.toLowerCase(), v]));
  const hit = { method: req.method, url: req.url, headers, authorization: headers.authorization || '', cookie: headers.cookie || '', ...extra };
  hits.push(hit);
  console.log(JSON.stringify(hit));
  return hit;
}

const body = (req, callback) => {
  let raw = '';
  req.on('data', chunk => { raw += chunk; });
  req.on('end', () => callback(raw));
};

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1:' + port);

  if (url.pathname === '/health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }

  if (url.pathname === '/report') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(hits.splice(0, hits.length)));
    return;
  }

  // /r/301?to=/target&absolute=1
  const redirect = /^\/r\/(301|302|303|307|308)$/.exec(url.pathname);
  if (redirect) {
    const code = Number(redirect[1]);
    const to = url.searchParams.get('to') || '/target';
    const location = url.searchParams.get('absolute') === '1' ? 'http://127.0.0.1:' + port + to : to;
    record(req, { code });
    res.writeHead(code, { Location: location, 'Content-Type': 'text/plain' });
    res.end('redirect ' + code);
    return;
  }

  if (url.pathname === '/loop/a' || url.pathname === '/loop/b') {
    record(req, { loop: true });
    res.writeHead(302, { Location: url.pathname === '/loop/a' ? '/loop/b' : '/loop/a' });
    res.end();
    return;
  }

  // /hop/7 redirects seven times before /target, so a five-hop ceiling must stop it.
  const hop = /^\/hop\/(\d+)$/.exec(url.pathname);
  if (hop) {
    const left = Number(hop[1]);
    record(req, { hop: left });
    res.writeHead(302, { Location: left > 0 ? '/hop/' + (left - 1) : '/target' });
    res.end();
    return;
  }

  if (url.pathname === '/slow') {
    record(req, { slow: true });
    setTimeout(() => { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('slow'); }, Number(url.searchParams.get('ms') || 5000));
    return;
  }

  if (url.pathname === '/missing') { record(req, { missing: true }); res.writeHead(404); res.end('not found'); return; }

  body(req, raw => {
    record(req, { body: raw });
    if (url.pathname === '/target' || url.pathname === '/echo') {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('target reached');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('ok');
  });
}).listen(port, '0.0.0.0', () => console.log('Redirect fixture server on ' + port));
