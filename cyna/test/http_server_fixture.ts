import { serve } from 'std:http';

const server = serve({ port: 0, async handler(request) {
  await new Promise(resolve => setTimeout(resolve, 2));
  if (request.url === '/stop') {
    console.log('stop entered');
    server.close();
    await new Promise(resolve => setTimeout(resolve, 2));
    console.log('stop settled');
    return { body: 'unreachable' };
  }
  if (request.url === '/json') return { json: { method: request.method, body: request.json() } };
  if (request.url === '/bytes') return { body: request.bytes() };
  if (request.url === '/error') throw Error('private details');
  if (request.url === '/invalid-header') return { headers: { test: 'x\r\ny: z' } };
  return { body: 'Hello 世界 🐈', headers: { 'X-Test': 'yes' } };
} });
console.log(server.port);
