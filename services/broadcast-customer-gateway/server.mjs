import {createHmac, createHash, randomBytes} from 'node:crypto';
import {createServer} from 'node:http';
import {pathToFileURL} from 'node:url';

const pendingCookie = 'orendam_broadcast_pending';
const sessionCookie = 'orendam_broadcast_session';
const sha256 = value => createHash('sha256').update(value).digest('hex');
const uuid = value => typeof value === 'string' &&
  /^[a-f0-9]{8}-[a-f0-9]{4}-[1-8a-f][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(value);

function cookies(header) {
  return Object.fromEntries((header ?? '').split(';').map(part => part.trim().split('='))
    .filter(pair => pair.length === 2));
}

async function imageBytes(request) {
  const type=request.headers['content-type'];
  if (!['image/png','image/jpeg','image/webp'].includes(type)) throw new Error('IMAGE_TYPE');
  const chunks=[];let size=0;
  for await(const chunk of request){
    size+=chunk.length;
    if(size>5242880) throw new Error('IMAGE_TOO_LARGE');
    chunks.push(chunk);
  }
  const bytes=Buffer.concat(chunks);
  const png=bytes.length>=8 && bytes.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex'));
  const jpeg=bytes.length>=3 && bytes[0]===255 && bytes[1]===216 && bytes[2]===255;
  const webp=bytes.length>=12 && bytes.toString('ascii',0,4)==='RIFF' &&
    bytes.toString('ascii',8,12)==='WEBP';
  if (!bytes.length || !((type==='image/png'&&png)||(type==='image/jpeg'&&jpeg)||
    (type==='image/webp'&&webp))) throw new Error('IMAGE_MAGIC');
  return {bytes,type};
}

async function bodyJson(request) {
  if (!request.headers['content-type']?.startsWith('application/json')) throw new Error('JSON_REQUIRED');
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 4096) throw new Error('BODY_TOO_LARGE');
  }
  const parsed = JSON.parse(body);
  if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') throw new Error('JSON_OBJECT_REQUIRED');
  return parsed;
}

export function createCustomerGateway({backendUrl, serviceKey, sessionSecret, origin, allowInsecureLocal=false}) {
  if (!backendUrl || !serviceKey || !sessionSecret || sessionSecret.length < 32 || !origin) {
    throw new Error('Gateway backend, key, 32+ character session secret and origin are required');
  }
  const originUrl = new URL(origin);
  if (originUrl.pathname !== '/' || originUrl.search || originUrl.hash) throw new Error('Gateway origin must have no path');
  const insecureLocal = allowInsecureLocal && originUrl.protocol === 'http:' &&
    ['localhost','127.0.0.1','[::1]'].includes(originUrl.hostname);
  if (originUrl.protocol !== 'https:' && !insecureLocal) throw new Error('HTTPS origin is required');
  const secure = originUrl.protocol === 'https:';
  const backend = backendUrl.replace(/\/$/, '');
  // New Supabase secret keys are API keys, not JWTs. Sending one as a bearer
  // token makes PostgREST reject it as an invalid JWT.
  const backendAuthHeaders = serviceKey.startsWith('sb_secret_')
    ? {apikey:serviceKey}
    : {apikey:serviceKey,authorization:`Bearer ${serviceKey}`};
  const cookie = (name, value, age) =>
    `${name}=${value}; Path=/api/broadcast/v2; HttpOnly; SameSite=Lax; Max-Age=${age}${secure ? '; Secure' : ''}`;
  const respond = (response, status, value, setCookies=[]) => {
    response.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      ...(setCookies.length ? {'set-cookie': setCookies} : {}),
    });
    response.end(JSON.stringify(value));
  };
  const rpc = async (name, params) => {
    const response = await fetch(`${backend}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {'content-type': 'application/json',...backendAuthHeaders},
      body: JSON.stringify(params),
    });
    if (!response.ok) throw new Error(`RPC_${response.status}`);
    return response.json();
  };
  return createServer(async (request, response) => {
    const url = new URL(request.url, origin);
    const jar = cookies(request.headers.cookie);
    try {
      if (request.method === 'POST' && request.headers.origin !== origin) {
        respond(response, 403, {error:'요청 출처를 확인해주세요.'}); return;
      }
      if (request.method === 'POST' && url.pathname === '/api/broadcast/v2/access/request') {
        const body = await bodyJson(request);
        if (!uuid(body.locator)) { respond(response,400,{error:'링크를 확인해주세요.'}); return; }
        const pending = /^[A-Za-z0-9_-]{43}$/.test(jar[pendingCookie] ?? '')
          ? jar[pendingCookie] : randomBytes(32).toString('base64url');
        const result = await rpc('broadcast_access_request',{
          p_locator:body.locator,p_pending_hash:sha256(pending),
        });
        respond(response,200,result,[cookie(pendingCookie,pending,48*3600)]); return;
      }
      if (request.method === 'POST' && url.pathname === '/api/broadcast/v2/access/activate') {
        const body = await bodyJson(request);
        const pending = jar[pendingCookie];
        if (!uuid(body.request_id) || !uuid(body.token) || !pending) {
          respond(response,403,{error:'요청한 기기와 활성화 링크를 확인해주세요.'}); return;
        }
        // A lost response can repeat the same activation without creating a
        // second session. The HMAC key never leaves this server.
        const session = createHmac('sha256',sessionSecret)
          .update(`${pending}:${body.token}`).digest('hex');
        const result = await rpc('broadcast_access_activate',{
          p_request_id:body.request_id,p_pending_hash:sha256(pending),
          p_token_hash:sha256(body.token),p_session_hash:sha256(session),
        });
        respond(response,200,result,[cookie(sessionCookie,session,30*24*3600)]); return;
      }
      const customerRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)$/i);
      const requestsRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/requests$/i);
      const billingRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/billing$/i);
      const addressRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/address$/i);
      const acceptRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/invoices\/([a-f0-9-]+)\/accept$/i);
      const evidenceRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/evidence$/i);
      const receiptsRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/receipts$/i);
      const needsInfoRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/receipts\/needs-info$/i);
      const supplementRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/receipts\/([a-f0-9-]+)\/supplement$/i);
      const paymentsRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/payments$/i);
      const depositReturnsRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/deposit-returns$/i);
      const receiverQrRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/invoices\/([a-f0-9-]+)\/receiver-qr\/(wechat|alipay)$/i);
      const shipmentsRoute = url.pathname.match(/^\/api\/broadcast\/v2\/customer\/([a-f0-9-]+)\/shipments$/i);
      if (receiverQrRoute && request.method==='GET') {
        const locator=receiverQrRoute[1],invoiceId=receiverQrRoute[2],method=receiverQrRoute[3];
        const session=jar[sessionCookie];
        if (!uuid(locator) || !uuid(invoiceId) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        const qr=await rpc('broadcast_guest_receiver_qr',{
          p_locator:locator,p_session_hash:sha256(session),p_invoice_id:invoiceId,p_method:method,
        });
        if (!/^[a-f0-9-]{36}\/[a-f0-9-]{36}\.(png|jpg)$/.test(qr.object_key??'') ||
          !['image/png','image/jpeg'].includes(qr.content_type)) throw new Error('QR_OBJECT_INVALID');
        const file=await fetch(`${backend}/storage/v1/object/authenticated/broadcast-receiver-qr/${qr.object_key}`,
          {headers:backendAuthHeaders});
        if (!file.ok) throw new Error('QR_STORAGE_READ_FAILED');
        const bytes=Buffer.from(await file.arrayBuffer());
        if (!bytes.length || bytes.length>2097152) throw new Error('QR_OBJECT_INVALID');
        response.writeHead(200,{'content-type':qr.content_type,'content-length':bytes.length,
          'cache-control':'private, no-store','referrer-policy':'no-referrer',
          'x-content-type-options':'nosniff'});
        response.end(bytes); return;
      }
      if (depositReturnsRoute && request.method==='GET') {
        const locator=depositReturnsRoute[1],session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        respond(response,200,await rpc('broadcast_guest_deposit_returns',{
          p_locator:locator,p_session_hash:sha256(session),
        })); return;
      }
      if ((needsInfoRoute && request.method==='GET') || (supplementRoute && request.method==='POST')) {
        const locator=(needsInfoRoute??supplementRoute)[1],session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        const auth={p_locator:locator,p_session_hash:sha256(session)};
        if (needsInfoRoute) {
          respond(response,200,await rpc('broadcast_guest_receipt_needs_info',auth)); return;
        }
        const body=await bodyJson(request);
        if (!uuid(supplementRoute[2]) || !uuid(body.evidence_id)) {
          respond(response,400,{error:'보완할 증빙을 확인해주세요.'}); return;
        }
        respond(response,200,await rpc('broadcast_guest_receipt_supplement',{
          ...auth,p_receipt_id:supplementRoute[2],p_evidence_id:body.evidence_id,
        })); return;
      }
      if (shipmentsRoute && request.method==='GET') {
        const locator=shipmentsRoute[1],session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        respond(response,200,await rpc('broadcast_guest_shipments',{
          p_locator:locator,p_session_hash:sha256(session),
        })); return;
      }
      if ((receiptsRoute&&request.method==='POST') || (paymentsRoute&&request.method==='GET')) {
        const locator=(receiptsRoute??paymentsRoute)[1],session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        const auth={p_locator:locator,p_session_hash:sha256(session)};
        if (paymentsRoute) {
          respond(response,200,await rpc('broadcast_guest_payment_summary',auth)); return;
        }
        const body=await bodyJson(request);
        if (!uuid(body.evidence_id) || !['KRW','CNY'].includes(body.currency) ||
          !Number.isSafeInteger(body.amount_minor) || body.amount_minor<=0 ||
          typeof body.payer_name!=='string' || body.payer_name.length>100) {
          respond(response,400,{error:'송금 정보를 확인해주세요.'}); return;
        }
        respond(response,200,await rpc('broadcast_guest_receipt_submit',{
          ...auth,p_evidence_id:body.evidence_id,p_currency:body.currency,
          p_claimed_minor:body.amount_minor,p_payer_name:body.payer_name,
        })); return;
      }
      if (evidenceRoute && request.method==='POST') {
        const locator=evidenceRoute[1],session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        const invoiceId=url.searchParams.get('invoice'),key=url.searchParams.get('key');
        if (!uuid(invoiceId) || !uuid(key)) {
          respond(response,400,{error:'정산서와 업로드 키를 확인해주세요.'}); return;
        }
        const {bytes,type}=await imageBytes(request);
        const digest=sha256(bytes);
        const reserved=await rpc('broadcast_guest_evidence_reserve',{
          p_locator:locator,p_session_hash:sha256(session),p_invoice_id:invoiceId,
          p_key:key,p_content_type:type,p_size:bytes.length,
        });
        if (reserved.status==='stored' && reserved.sha256!==digest) {
          respond(response,409,{error:'같은 업로드 키에 다른 파일을 사용할 수 없습니다.'}); return;
        }
        if (reserved.status!=='stored') {
          const objectUrl=`${backend}/storage/v1/object/broadcast-evidence/${reserved.object_key}`;
          const headers={...backendAuthHeaders};
          const uploaded=await fetch(objectUrl,{method:'POST',headers:{...headers,'content-type':type},body:bytes});
          if (!uploaded.ok) {
            const existing=await fetch(`${backend}/storage/v1/object/authenticated/broadcast-evidence/${reserved.object_key}`,
              {headers});
            if (!existing.ok || sha256(Buffer.from(await existing.arrayBuffer()))!==digest) {
              throw new Error('STORAGE_UPLOAD_FAILED');
            }
          }
          await rpc('broadcast_evidence_stored',{
            p_evidence_id:reserved.evidence_id,p_size:bytes.length,p_sha256:digest,
          });
        }
        respond(response,200,{evidence_id:reserved.evidence_id,status:'stored'}); return;
      }
      if (billingRoute || addressRoute || acceptRoute) {
        const locator=(billingRoute??addressRoute??acceptRoute)[1],session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        const auth={p_locator:locator,p_session_hash:sha256(session)};
        if (billingRoute && request.method==='GET') {
          respond(response,200,await rpc('broadcast_guest_billing',auth)); return;
        }
        if (addressRoute && request.method==='POST') {
          const body=await bodyJson(request);
          if (!body.address || typeof body.address!=='object' || Array.isArray(body.address) ||
              !Number.isInteger(body.expected_version)) {
            respond(response,400,{error:'주소 요청을 확인해주세요.'}); return;
          }
          respond(response,200,await rpc('broadcast_guest_address',{
            ...auth,p_address:body.address,p_expected_version:body.expected_version,
          })); return;
        }
        if (acceptRoute && request.method==='POST' && uuid(acceptRoute[2])) {
          await bodyJson(request);
          respond(response,200,await rpc('broadcast_guest_invoice_accept',{
            ...auth,p_invoice_id:acceptRoute[2],
          })); return;
        }
      }
      if (requestsRoute && ['GET','POST'].includes(request.method)) {
        const locator=requestsRoute[1], session=jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        if (request.method==='GET') {
          respond(response,200,await rpc('broadcast_guest_requests',{
            p_locator:locator,p_session_hash:sha256(session),
          })); return;
        }
        const body=await bodyJson(request);
        if (!['addition','change'].includes(body.kind) || !uuid(body.target_id) ||
            !uuid(body.request_key) || typeof body.raw_text!=='string' ||
            body.raw_text.trim().length<1 || body.raw_text.length>500) {
          respond(response,400,{error:'요청 내용을 확인해주세요.'}); return;
        }
        respond(response,200,await rpc('broadcast_guest_request',{
          p_locator:locator,p_session_hash:sha256(session),p_kind:body.kind,
          p_target_id:body.target_id,p_raw_text:body.raw_text,p_key:body.request_key,
        })); return;
      }
      if (request.method === 'GET' && customerRoute) {
        const locator = customerRoute[1], session = jar[sessionCookie];
        if (!uuid(locator) || !session || !/^[a-f0-9]{64}$/.test(session)) {
          respond(response,401,{error:'이 기기의 접근 확인이 필요합니다.'}); return;
        }
        const result = await rpc('broadcast_guest_view',{
          p_locator:locator,p_session_hash:sha256(session),
        });
        respond(response,200,result); return;
      }
      respond(response,404,{error:'경로를 찾을 수 없습니다.'});
    } catch (error) {
      const badInput = ['JSON_REQUIRED','BODY_TOO_LARGE','JSON_OBJECT_REQUIRED','SyntaxError',
        'IMAGE_TYPE','IMAGE_TOO_LARGE','IMAGE_MAGIC'].some(
        value => error.message.includes(value));
      respond(response,badInput ? 400 : error.message.startsWith('RPC_4') ? 403 : 502,
        {error:badInput ? '요청 형식을 확인해주세요.' :
          error.message.startsWith('RPC_4') ? '링크 또는 기기 확인이 필요합니다.' : '잠시 후 다시 시도해주세요.'});
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = createCustomerGateway({
    backendUrl:process.env.BROADCAST_BACKEND_URL,
    serviceKey:process.env.BROADCAST_SERVICE_KEY,
    sessionSecret:process.env.BROADCAST_GATEWAY_SESSION_SECRET,
    origin:process.env.BROADCAST_GATEWAY_ORIGIN,
    allowInsecureLocal:process.env.BROADCAST_GATEWAY_INSECURE_LOCAL === '1',
  });
  server.listen(Number(process.env.PORT ?? 8788),process.env.HOST ?? '127.0.0.1');
}
