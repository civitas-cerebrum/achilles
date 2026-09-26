// pi/tests/live/record-proxy.mjs — a pass-through HTTP proxy for the live checks: forwards every
// request to <upstream> unchanged (responses stream back as they arrive) and appends each request's
// JSON body as one line to <record.jsonl>. Writes the port it listens on to <portfile>.
// Usage: node record-proxy.mjs <upstream-origin> <record.jsonl> <portfile>
import http from 'node:http';
import fs from 'node:fs';
const [upstream, record, portfile] = process.argv.slice(2);
const target = new URL(upstream);
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    if (body.length) { try { fs.appendFileSync(record, JSON.stringify(JSON.parse(body.toString('utf8'))) + '\n'); } catch { /* not JSON */ } }
    const up = http.request({ hostname: target.hostname, port: target.port, path: req.url, method: req.method, headers: { ...req.headers, host: target.host } }, (r) => {
      res.writeHead(r.statusCode ?? 502, r.headers);
      r.pipe(res);
    });
    up.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
    up.end(body);
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portfile, String(server.address().port)));
