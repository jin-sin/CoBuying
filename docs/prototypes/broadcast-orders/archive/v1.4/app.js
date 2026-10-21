/* 검토용 모의 UI. 네트워크·인증·영구 저장·실제 송금 기능이 없다. */
'use strict';
const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money = (minor) => `¥${(minor / 100).toFixed(2)}`;
const clone = (value) => structuredClone(value);
const guestTemplate = () => ({nickname:'',contact:'',lines:[],savedLines:[],saved:false,dirty:false,address:null,invoice:null,cancelled:null,invoiceHistory:[],method:'wechat',evidence:null,upload:'empty',uploadError:'',reviewReason:'',history:[]});
const initialState = () => ({role:'customer',guest:'A',page:'catalog',closed:false,phase:'ordering',reviewGuest:'A',nextProductNumber:4,receiptRefs:[],guests:{A:guestTemplate(),B:guestTemplate()},products:[
  {id:'p01',number:'01',name:'데일리 라운드 니트',price:8800,colors:['아이보리','블랙','레드'],sizes:['FREE'],version:1,state:'published',everOrdered:false},
  {id:'p02',number:'02',name:'스트라이프 코튼 셔츠',price:10800,colors:['블루','화이트'],sizes:['M','L'],version:1,state:'published',everOrdered:false},
  {id:'p03',number:'03',name:'미니 레더 토트백',price:12800,colors:['브라운','블랙'],sizes:['단일 사이즈'],version:1,state:'published',everOrdered:false}
]});
let state = initialState();
let toastTimer;
let uploadCounter = 0;
const guest = () => state.guests[state.guest];
const count = (lines) => lines.reduce((sum,line) => sum + line.quantity,0);
const total = (lines) => lines.reduce((sum,line) => sum + line.quantity * line.price,0);
const statusText = (g) => g.cancelled ? '주문 취소 완료' : !g.saved ? '구매 요청 없음' : !g.invoice ? '청구 준비' : g.invoice.changeRequest ? (allRemovalRequested(g)?(state.role==='customer'?'취소 확인 대기':'전체 제외 요청'):(state.role==='customer'?'판매자 확인 대기':'고객 수정 요청')) : !g.invoice.accepted&&g.invoice.payment==='unpaid' ? '고객 확인 대기' : ({unpaid:'결제 대기',pending_review:'입금 확인 대기',needs_info:'추가 확인 필요',confirmed:g.invoice.shipped ? '배송중' : '입금 확인 완료'})[g.invoice.payment];
const button = (label,action,extra='',cls='') => `<button class="${cls}" data-action="${action}" ${extra}>${label}</button>`;
const lineKey=l=>JSON.stringify([l.id,l.color,l.size]); // 시안 안의 옵션별 식별. 실제 계약은 서버 requestLineId 사용.
const removalKeys=g=>g.invoice?.changeRequest?.removeLineKeys||[];
const activeInvoiceLines=g=>(g.invoice?.lines||[]).filter(l=>!l.excluded&&l.quantity>0);
function allRemovalRequested(g){const lines=activeInvoiceLines(g);return lines.length>0&&lines.every(l=>removalKeys(g).includes(lineKey(l)));}
function canRequestChange(g){return Boolean(g.invoice&&!g.cancelled&&g.invoice.payment==='unpaid'&&!g.invoice.changeRequest&&g.upload==='empty');}
function requestedRemovalList(g){
 const lines=(g.invoice?.lines||[]).filter(l=>removalKeys(g).includes(lineKey(l)));
 return lines.length?`<ul class="removal-list">${lines.map(l=>`<li><strong>${l.number} · ${esc(l.name)}</strong><br>${esc(l.color)} / ${esc(l.size)} · ${l.quantity}개 제외 요청</li>`).join('')}</ul>`:'';
}
function invoiceLines(g){
 const inv=g.invoice;
 const included=inv.lines.map((l,i)=>l.excluded?'':`<article class="invoice-item"><div class="list-line">${numberMark(l)}<div class="line-content"><strong>${esc(l.name)}</strong><p>${esc(l.color)} · ${esc(l.size)} · ${l.quantity}개</p>${l.quantity!==l.requested?`<span class="tag">요청 ${l.requested}개 → 확보 ${l.quantity}개</span>`:''}${l.price!==l.requestedPrice?`<p class="product-note">요청 시 단가 ${money(l.requestedPrice)} → 청구 단가 ${money(l.price)}</p>`:''}</div><span class="amount">${money(l.price*l.quantity)}</span></div>${removalKeys(g).includes(lineKey(l))?'<div class="notice push">제외 요청 중 · 담당자가 아직 반영하지 않았어요.</div>':canRequestChange(g)?button('이 상품 제외 요청','request-line-removal',`data-index="${i}" aria-label="${l.number}번 ${esc(l.color)} ${esc(l.size)} 제외 요청"`,'quiet full'):''}</article>`).join('');
 const excluded=inv.lines.filter(l=>l.excluded);
 return included+(excluded.length?`<section class="excluded-items push"><h3>청구에서 제외된 상품</h3>${excluded.map(l=>`<article><strong>${l.number} · ${esc(l.name)}</strong><p>${esc(l.color)} / ${esc(l.size)} · 청구 금액에 포함되지 않아요.</p><p>${esc(l.exclusionReason||inv.changeReason)}</p></article>`).join('')}</section>`:'');
}
function cancellationPanel(g){
 const inv=g.invoice;
 return `<section class="panel stack cancellation-panel"><span class="tag neutral">주문 취소 완료</span><h2>요청하신 주문을 취소했어요</h2><p>모든 상품의 제외 요청을 담당자가 확인했어요. 이 주문으로 송금할 금액은 없습니다.</p><div class="notice info">${esc(g.cancelled.reason)}</div><p class="small muted">취소 확인: ${esc(g.cancelled.by)} · ${esc(g.cancelled.at)}</p><details><summary>취소한 청구 내용 보기</summary><p class="small muted push">${inv.revision}차 청구서 · 취소 전 ${money(inv.total)} · 송금 대상 아님</p>${inv.lines.filter(l=>!l.excluded).map(l=>`<p class="small push">${l.number} · ${esc(l.name)} · ${esc(l.color)} / ${esc(l.size)} · ${l.quantity}개</p>`).join('')}</details>${invoiceHistory(g)}</section>`;
}
function confirmInvoiceCancellation(id){
 const g=state.guests[id];if(!g||g.cancelled||!allRemovalRequested(g)||g.invoice.accepted||g.invoice.payment!=='unpaid'||g.upload!=='empty')return notify('고객의 전체 제외 요청과 송금 상태를 확인해 주세요.');
 const dialog=$('#manage-dialog');dialog.innerHTML=`<div class="dialog-heading"><h2 id="manage-title">전체 주문 취소 확인</h2><button data-close="manage-dialog" aria-label="주문 취소 확인 닫기">×</button></div><p>${esc(g.nickname)}님이 현재 청구된 모든 상품의 제외를 요청했어요.</p>${requestedRemovalList(g)}<div class="notice">0원 청구서를 새로 발행하지 않고 이 주문과 현재 청구서를 취소합니다. 원 주문과 이전 청구 이력은 남습니다.</div><form id="cancel-invoiced-form" data-guest="${id}" data-revision="${g.invoice.revision}" data-change-id="${g.invoice.changeRequest.id}" class="stack push"><label class="field">취소 처리 사유<textarea name="reason" maxlength="300" required>${esc(g.invoice.changeRequest.reason)}</textarea></label><label class="check"><input name="verified" type="checkbox" required><span>고객의 전체 제외 요청과 미송금 확인을 검토했어요. 주문 취소로 처리합니다.</span></label><button class="dark full">주문 취소 확정</button></form>`;dialog.showModal();
}
function updateInvoiceDraft(form){
 const g=state.guests[form.dataset.guest],data=new FormData(form);
 const excluded=g.savedLines.map((l,i)=>data.get(`exclude-${i}`)==='1');
 const fresh=excluded.some((value,i)=>value&&!g.invoice?.lines.find(l=>lineKey(l)===lineKey(g.savedLines[i]))?.excluded);
 const all=excluded.every(Boolean),amount=g.savedLines.reduce((sum,l,i)=>sum+(excluded[i]?0:Number(data.get(`qty-${i}`))*Math.round(Number(data.get(`price-${i}`))*100)),Math.round(Number(data.get('shipping'))*100));
 form.querySelector('.invoice-draft-total').textContent=all?'전체 취소 확인 필요':Number.isSafeInteger(amount)&&amount>=0?money(amount):'입력값을 확인해 주세요';
 form.querySelector('.shipping-check').hidden=!fresh||all;form.querySelector('[name=shipping-reviewed]').required=fresh&&!all;
 form.querySelector('.all-excluded-notice').hidden=!all;form.querySelector('.invoice-publish').disabled=all;
}
function toggleInvoiceExclusion(b){
 const form=b.closest('.invoice-form'),i=Number(b.dataset.index),g=state.guests[form.dataset.guest],line=g.savedLines[i];if(!line||g.cancelled)return;
 const old=g.invoice?.lines.find(l=>lineKey(l)===lineKey(line));if(old?.excluded)return;
 const flag=form.querySelector(`[name="exclude-${i}"]`),qty=form.querySelector(`[name="qty-${i}"]`),price=form.querySelector(`[name="price-${i}"]`),excluded=flag.value!=='1';
 if(excluded){qty.dataset.previous=qty.value;qty.value='0';}else qty.value=qty.dataset.previous||String(old?.quantity||line.quantity);
 flag.value=excluded?'1':'0';qty.readOnly=excluded;price.readOnly=excluded;
 b.closest('.invoice-editor-line').classList.toggle('is-excluded',excluded);b.closest('.invoice-editor-line').querySelector('.exclusion-draft-note').hidden=!excluded;
 b.textContent=excluded?'제외 취소':'청구에서 제외';b.setAttribute('aria-label',`${line.number}번 ${line.color} ${line.size} ${excluded?'제외 취소':'청구에서 제외'}`);
 form.querySelector('[name=shipping-reviewed]').checked=false;form.querySelector('[name=reviewed]').checked=false;updateInvoiceDraft(form);
}
function seedExclusion(){
 Object.values(state.guests).forEach(releaseEvidence);state=initialState();seed();const g=guest();
 g.savedLines.push({...productById('p02'),color:'블루',size:'M',quantity:1});g.lines=clone(g.savedLines);productById('p02').everOrdered=true;
 g.invoice=null;g.invoiceHistory=[];g.invoice=buildInvoice(g,g.savedLines.map(l=>({...l,requested:l.quantity,requestedPrice:l.price,excluded:false})),1200,'');
 g.invoiceHistory.push(clone(g.invoice));g.invoice=buildInvoice(g,g.invoice.lines.map(l=>({...l,price:l.id==='p01'?9800:l.price})),1200,'01번 니트 단가를 88위안에서 98위안으로 정정합니다.');
 productById('p01').state='paused';productById('p01').version++;state.page='invoice';render();notify('두 상품의 제외 요청을 체험해 보세요. 하나만 빼거나 모두 선택할 수 있어요.');
}
function canReissue(g){return Boolean(g.invoice&&!g.cancelled&&!allRemovalRequested(g)&&g.invoice.payment==='unpaid'&&!g.invoice.accepted&&g.upload==='empty');}
function buildInvoice(g,lines,shipping,reason){
 const previous=g.invoice,baseline=previous?.lines||g.savedLines,changes=[];
 lines.forEach(l=>{const old=baseline.find(x=>lineKey(x)===lineKey(l));if(l.excluded&&!old.excluded){changes.push({label:`${l.number}번 ${l.color} / ${l.size}`,before:`${old.quantity}개 · ${money(old.price*old.quantity)}`,after:'청구에서 제외'});return;}if(l.price!==old.price)changes.push({label:`${l.number}번 개당 가격`,before:money(old.price),after:money(l.price)});if(l.quantity!==old.quantity)changes.push({label:`${l.number}번 수량`,before:`${old.quantity}개`,after:`${l.quantity}개`});});
 const amount=total(lines)+shipping;
 if(previous&&previous.shipping!==shipping)changes.push({label:'중국 배송비',before:money(previous.shipping),after:money(shipping)});
 if(previous&&previous.total!==amount)changes.push({label:'총 송금 금액',before:money(previous.total),after:money(amount)});
 return {revision:(previous?.revision||0)+1,lines,shipping,total:amount,changeReason:reason,changes,changeRequest:null,resolvedChangeRequest:previous?.changeRequest?clone(previous.changeRequest):null,accepted:false,payment:'unpaid',shipped:false};
}
function invoiceChanges(inv){
 if(!inv.changeReason&&!inv.changes.length)return '';
 return `<section class="correction-card"><span class="tag">${inv.accepted?'고객 확인 완료':'확인할 변경 내용'}</span><h3>${inv.accepted?'확인하신 변경 내용':'청구 내용을 확인해 주세요'}</h3>${inv.changeReason?`<p>${esc(inv.changeReason)}</p>`:''}${inv.changes.length?`<dl class="change-comparison">${inv.changes.map(c=>`<div><dt>${esc(c.label)}</dt><dd><span class="muted">변경 전</span> ${esc(c.before)}<br><strong><span>정정 후</span> ${esc(c.after)}</strong></dd></div>`).join('')}</dl>`:''}<p class="small muted">${inv.accepted?'확인한 청구 내용과 요청할 때의 상품 정보를 함께 보관해요.':'동의하기 전에는 송금하지 마세요. 요청할 때의 상품 정보는 아래에 함께 표시돼요.'}</p></section>`;
}
function invoiceHistory(g){
 if(!g.invoiceHistory.length)return '';
 return `<details class="invoice-history push"><summary>이전 청구서 ${g.invoiceHistory.length}건</summary>${g.invoiceHistory.map(inv=>`<article class="history-item"><div class="bill-row"><strong>${inv.revision}차 청구서</strong><span>${money(inv.total)}</span></div><span class="tag neutral">새 청구서로 대체됨 · 송금 대상 아님</span>${inv.lines.map(l=>`<p class="small">${l.number} · ${esc(l.name)} · ${esc(l.color)} / ${esc(l.size)} · ${l.quantity}개 × ${money(l.price)}</p>`).join('')}<p class="small">배송비 ${money(inv.shipping)}</p>${inv.changeReason?`<p class="small muted">정정 사유: ${esc(inv.changeReason)}</p>`:''}${inv.changeRequest?`<p class="small muted">고객 요청: ${esc(inv.changeRequest.reason)}</p>`:''}</article>`).join('')}</details>`;
}
function invoiceDecision(g){
 const inv=g.invoice;
 if(inv.changeRequest)return `<section class="panel stack"><span class="tag neutral">판매자 확인 대기</span><h2>${removalKeys(g).length?'상품 제외를 요청했어요':'수정 요청을 남겼어요'}</h2>${requestedRemovalList(g)}<div class="notice info">${esc(inv.changeRequest.reason)}</div><p>${allRemovalRequested(g)?'현재 청구된 모든 상품의 제외를 요청했어요. 담당자가 확인하면 주문 취소가 완료돼요.':'판매자가 요청을 확인하고 남은 상품과 배송비를 다시 안내해요.'}</p><p class="small muted">아직 처리 전이에요. 지금은 송금하지 마세요.</p></section>`;
 if(inv.accepted)return paymentPanel(g);
 return `<form id="accept-form" data-revision="${inv.revision}" class="panel stack"><h2>${inv.changeReason?'정정 내용에 동의하시나요?':'최종 내용을 확인해 주세요'}</h2><p class="muted">상품·수량·가격·배송비를 확인해 주세요. 동의하면 이 청구서의 송금 안내가 열려요.</p><label class="check"><input type="checkbox" name="agree" required><span>${inv.changeReason?'정정 사유와 변경 금액을 포함한 최종 청구 내용을 확인했어요.':'상품·수량·배송비와 최종 금액을 확인했어요.'}</span></label><button class="primary full">${inv.changeReason?'동의하고 송금 안내 보기':'확인하고 송금 안내 보기'}</button>${button('동의하지 않아요 · 수정 요청','request-invoice-change','type="button"','full')}<p class="small muted">상품을 빼고 싶다면 각 상품의 ‘이 상품 제외 요청’을 이용해 주세요.</p></form>`;
}
function invoiceFields(id,g){
 const inv=g.invoice,disabled=!state.closed||!g.address;
 return `<form class="invoice-form stack" data-guest="${id}" data-revision="${inv?.revision||0}" data-change-id="${inv?.changeRequest?.id||''}"><fieldset class="product-fieldset stack" ${disabled?'disabled':''}>${g.savedLines.map((l,i)=>{
 const value=inv?.lines.find(x=>lineKey(x)===lineKey(l))||l,excluded=Boolean(value.excluded),requested=removalKeys(g).includes(lineKey(l));
 return `<section class="invoice-editor-line ${excluded?'is-excluded':''}" data-index="${i}"><strong>${l.number} · ${esc(l.name)}</strong><p class="small muted">${esc(l.color)} / ${esc(l.size)} · 요청 ${l.quantity}개 · 요청 시 단가 ${money(l.price)}</p>${requested?'<div class="notice push">고객이 이 상품 전체의 제외를 요청했어요.</div>':''}<input type="hidden" name="exclude-${i}" value="${excluded?'1':'0'}"><div class="fields two push"><label class="field">${l.number}번 확보 수량<input name="qty-${i}" type="number" min="1" max="${l.quantity}" value="${value.quantity}" ${excluded?'readonly':''} required></label><label class="field">${l.number}번 청구 단가 (CNY)<input name="price-${i}" type="number" min="0.01" step="0.01" value="${(value.price/100).toFixed(2)}" ${excluded?'readonly':''} required></label></div><p class="exclusion-draft-note small push" ${excluded?'':'hidden'}>${excluded?'이전 청구에서 제외된 상품 · 다시 포함할 수 없어요':'새 청구서에서 제외할 예정 · 아직 고객 화면에는 반영되지 않았어요'}</p>${excluded?'':button('청구에서 제외','exclude-invoice-line',`type="button" data-index="${i}" aria-label="${l.number}번 ${esc(l.color)} ${esc(l.size)} 청구에서 제외"`,'full push')}</section>`;
 }).join('')}<label class="field">중국 배송비 (CNY)<input name="shipping" type="number" min="0" step="0.01" value="${((inv?.shipping??1200)/100).toFixed(2)}" required></label><label class="check shipping-check" hidden><input name="shipping-reviewed" type="checkbox"><span>남은 상품 기준으로 배송비를 다시 확인했어요.</span></label><div class="notice error all-excluded-notice" hidden>전부 제외하는 경우 새 청구서를 발행하지 않습니다. 고객의 전체 제외 요청을 확인한 뒤 주문 취소로 처리해 주세요.</div><label class="field">고객에게 안내할 변경 사유<textarea name="reason" maxlength="300" placeholder="예: 고객 요청으로 01번 니트를 제외하고 배송비를 다시 계산했어요." ${inv?'required':''}></textarea><span class="hint">상품 제외·수량·단가가 달라지거나 청구서를 다시 발행하면 필수예요.</span></label><div class="bill-row total"><span>${inv?'정정 후 총액':'청구 예정 금액'}</span><output class="amount invoice-draft-total">${money(inv?.total??total(g.savedLines)+1200)}</output></div><label class="check"><input name="reviewed" type="checkbox" required><span>상품과 금액·변경 사유를 확인했어요. 고객이 동의해야 송금 안내가 열려요.</span></label><button class="primary full invoice-publish">${inv?'정정 청구서 발행':`${esc(g.nickname)}님 청구서 발행`}</button></fieldset><p class="small muted">${!state.closed?'구매 요청을 마감한 뒤 청구서를 준비할 수 있어요.':!g.address?'고객 배송지 입력을 기다리고 있어요.':'상품 이름·옵션은 요청 내용으로 고정돼요. 제외한 상품도 이력에 남아요.'}</p></form>`;
}
function editInvoice(id){
 const g=state.guests[id];if(!canReissue(g))return notify('고객 동의 또는 송금이 진행 중이어서 직접 정정할 수 없어요.');
 const dialog=$('#manage-dialog');dialog.innerHTML=`<div class="dialog-heading"><h2 id="manage-title">${esc(g.nickname)}님 청구서 정정</h2><button data-close="manage-dialog" aria-label="청구서 정정 닫기">×</button></div><div class="notice push">현재 ${g.invoice.revision}차 청구 금액은 <strong>${money(g.invoice.total)}</strong>이에요. 정정하면 이전 청구서는 송금 대상에서 제외되고 고객이 새 내용을 확인해야 해요.</div>${g.invoice.changeRequest?`<p class="notice info">고객 요청: ${esc(g.invoice.changeRequest.reason)}</p>${requestedRemovalList(g)}`:''}<div class="push">${invoiceFields(id,g)}</div>`;dialog.showModal();
}
function requestInvoiceChange(selectedIndex=null){
 const g=guest(),inv=g.invoice;if(!canRequestChange(g))return notify('송금 확인이 시작되었거나 처리 중인 요청이 있어요. 현재 상태를 확인해 주세요.');
 if(selectedIndex!==null&&(!inv.lines[selectedIndex]||inv.lines[selectedIndex].excluded))return;
 const dialog=$('#manage-dialog');dialog.innerHTML=`<div class="dialog-heading"><h2 id="manage-title">${selectedIndex===null?'청구 내용 수정 요청':'상품 제외 요청'}</h2><button data-close="manage-dialog" aria-label="청구 수정 요청 닫기">×</button></div><p>${inv.revision}차 청구서 · ${money(inv.total)}</p><form id="invoice-change-form" data-revision="${inv.revision}" class="stack"><fieldset class="product-fieldset stack"><legend>제외할 상품을 골라 주세요 (선택)</legend>${inv.lines.map((l,i)=>l.excluded?'':`<label class="check removal-choice"><input type="checkbox" name="remove-line" value="${i}" ${i===selectedIndex?'checked':''}><span><strong>${l.number} · ${esc(l.name)}</strong><br>${esc(l.color)} / ${esc(l.size)} · ${l.quantity}개 · ${money(l.price*l.quantity)}</span></label>`).join('')}</fieldset><label class="field">다시 확인할 내용<textarea name="reason" maxlength="300" required placeholder="요청 사유를 알려 주세요.">${selectedIndex!==null?'선택한 상품을 제외해 주세요.':''}</textarea></label><label class="check removal-confirm" ${selectedIndex===null?'hidden':''}><input type="checkbox" name="confirm-removal" ${selectedIndex===null?'':'required'}><span>선택한 상품의 제외를 요청해요. 현재 청구 상품을 전부 선택하면 주문 취소를 요청합니다.</span></label><label class="check"><input type="checkbox" name="not-transferred" required><span>아직 송금하지 않았어요. 처리 결과를 확인할 때까지 송금하지 않을게요.</span></label><div class="notice">담당자가 확인하기 전에는 청구 금액이 그대로 남아요. 요청을 남기면 송금 안내가 닫혀요.</div><button class="primary full removal-submit">${selectedIndex===null?'수정 요청 남기기':'상품 제외 요청 남기기'}</button></form>`;dialog.showModal();
}
function seedCorrection(){
 Object.values(state.guests).forEach(releaseEvidence);state=initialState();seed();
 const g=guest();g.invoiceHistory.push(clone(g.invoice));g.invoice=buildInvoice(g,g.invoice.lines.map(l=>({...l,price:9800})),1200,'01번 상품의 단가를 잘못 안내했어요. 88위안에서 98위안으로 정정합니다.');
 productById('p01').state='paused';productById('p01').version++;state.page='invoice';render();notify('정정 예시를 불러왔어요. 동의하거나 수정 요청을 남겨 보세요.');
}
function notify(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),3200);}
function releaseEvidence(g){if(g.evidence?.url) URL.revokeObjectURL(g.evidence.url);g.evidence=null;g.upload='empty';g.uploadError='';}
function header(label){return `<header class="site-header"><div class="header-inner"><div class="brand"><span class="brand-mark" aria-hidden="true">o</span>오렌담마켓<span class="header-caption">${label}</span></div>${state.role==='customer'?button('내 주문 찾기','help','','quiet'):'<span class="tag neutral">'+(state.role==='operator'?'보조 담당자':'수금 확인 권한')+'</span>'}</div></header>`;}
function render(){
  document.querySelectorAll('[data-role]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.role===state.role)));
  $('#demo-guest').value=state.guest;
  $('#demo-guest').disabled=state.role!=='customer';
  $('#app').innerHTML=state.role==='customer'?customer():state.role==='operator'?operator():collector();
}
function customer(){
 const g=guest();
 return `${header('방송 상품 주문')}<main class="page"><div class="intro"><div><span class="eyebrow">ORENDAM · LIVE SHOPPING</span><h1>${state.page==='catalog'?'방송에서 본 상품,<br>여기 담아두세요.':state.page==='request'?'내 구매 요청':'청구서와 입금 확인'}</h1><p>샘플옷장 · 9월 13일 현장 방송 <span class="tag ${state.closed?'neutral':'green'}">${state.closed?'구매 요청 마감':state.phase==='ordering'?'지금은 주문 시간':'상품 소개 중'}</span></p></div><div class="session-note"><strong>가입 없이 주문할 수 있어요</strong>배송지와 결제는 방송 후 한 번에</div></div>
 <nav class="customer-nav" aria-label="고객 메뉴">${[['catalog','방송 상품'],['request',`내 구매 요청 <span class="count">${count(g.lines)}</span>`],['invoice','청구·입금']].map(([p,l])=>`<button data-page="${p}" ${state.page===p?'aria-current="page"':''}>${l}</button>`).join('')}</nav>
 ${state.page==='catalog'?catalog():state.page==='request'?requestPage():invoicePage()}
 <p class="footer-note">시안의 이름·상품·금액은 예시입니다. 새로고침하면 체험 내용이 초기화됩니다.</p></main>`;
}
function numberMark(p,large=false){return `<span class="number-mark ${large?'large':''}" aria-label="상품 ${esc(p.number)}번">${esc(p.number)}</span>`;}
function productById(id){return state.products.find(p=>p.id===id);}
function sameLine(a,b){return a.id===b.id&&a.color===b.color&&a.size===b.size;}
function savedLineCovers(l){const saved=guest().savedLines.find(x=>sameLine(x,l));return Boolean(saved&&l.version===saved.version&&l.quantity<=saved.quantity);}
function productNotice(l){const current=productById(l.id);if(!current||current.state==='deleted')return '목록에서 삭제됨 · 이 상품을 빼고 저장해 주세요';if(current.state==='paused')return savedLineCovers(l)?'판매 중지 · 저장된 요청은 유지돼요':'판매 중지 · 새 요청을 저장할 수 없어요';if(current.version!==l.version)return savedLineCovers(l)?'판매 상태 변경 · 저장된 요청은 유지돼요':'담은 뒤 상품 정보가 바뀌었어요 · 확인이 필요해요';return '';}
function productComparison(previous,current){
 const options=p=>`${p.colors.length?p.colors.join(', '):'색상 직접 입력'} / ${p.sizes.length?p.sizes.join(', '):'사이즈 직접 입력'}`;
 const changes=[];
 if(previous.name!==current.name)changes.push(['상품 이름',previous.name,current.name]);
 if(previous.price!==current.price)changes.push(['개당 가격',money(previous.price),money(current.price)]);
 if(JSON.stringify([previous.colors,previous.sizes])!==JSON.stringify([current.colors,current.sizes]))changes.push(['선택 옵션',options(previous),options(current)]);
 if(!changes.length)changes.push(['판매 상태','담았을 때의 정보','현재 구매 요청 가능']);
 return `<dl class="change-comparison">${changes.map(([label,before,after])=>`<div><dt>${label}</dt><dd><span class="muted">변경 전</span> ${esc(before)}<br><strong><span>현재</span> ${esc(after)}</strong></dd></div>`).join('')}</dl>`;
}
function validateLines(g){
  for(const l of g.lines){
    const current=productById(l.id),saved=g.savedLines.find(x=>sameLine(x,l));
    if(saved&&l.version===saved.version&&l.quantity<=saved.quantity)continue;
    if(!current||current.state!=='published')return `${l.number}번은 현재 요청할 수 없어요. 해당 항목을 빼고 저장해 주세요.`;
    if(l.version!==current.version)return `${l.number}번의 변경 내용을 확인하거나 이 상품을 빼야 저장할 수 있어요.`;
  }
  return null;
}
function catalog(){
 const g=guest(),products=state.products.filter(p=>p.state!=='deleted');
 return `<div class="customer-layout"><section class="stack"><div class="notice ${state.closed?'info':''}">${state.closed?'이번 방송의 구매 요청이 마감됐어요. 내 요청과 청구서를 확인해 주세요.':'방송에서 안내한 번호로 찾아주세요. 예: “01번 라운드 니트”'}</div><div class="catalog text-catalog">${products.map(p=>`<article class="product text-product"><div class="text-product-head">${numberMark(p,true)}<span class="tag ${p.state==='paused'?'neutral':'green'}">${p.state==='paused'?'판매 중지':'구매 요청 가능'}</span></div><div class="product-body"><h3>${esc(p.name)}</h3><p class="muted small">${p.colors.length?p.colors.map(esc).join(' · '):'원하는 색상을 직접 적어 주세요'}</p><p class="amount">${money(p.price)} <span class="muted small">CNY</span></p>${button(state.closed?'요청 마감':p.state==='paused'?'판매 중지':'옵션·수량 선택','product',`data-id="${p.id}" ${state.closed||p.state!=='published'?'disabled':''}`)}</div></article>`).join('')||'<div class="panel empty"><h2>아직 등록된 상품이 없어요</h2><p class="muted">상품이 등록되면 번호와 이름이 여기에 표시돼요.</p></div>'}</div></section><aside class="support-card"><h3>이번 방송, 이렇게 주문해요</h3><ol class="steps"><li><span class="number">1</span><div><strong>방송에서 상품 확인</strong><span class="muted">안내받은 번호와 이름으로 찾아요.</span></div></li><li><span class="number">2</span><div><strong>옵션·수량 선택 후 저장</strong><span class="muted">색상과 수량은 손님이 입력해요.</span></div></li><li><span class="number">3</span><div><strong>방송 후 청구서 확인</strong><span class="muted">배송비까지 확인하고 송금해요.</span></div></li></ol><div class="side-total"><div class="row between"><strong>내가 담은 상품</strong><span class="tag neutral">${count(g.lines)}개</span></div><div class="push">${g.lines.length?g.lines.map(l=>`<div class="mini-line"><span>${l.number} ${esc(l.name)} × ${l.quantity}</span><b>${money(l.price*l.quantity)}</b></div>`).join(''):'<p class="muted small">아직 담은 상품이 없어요.</p>'}</div>${button('내 구매 요청 확인','go-request','','primary full push')}</div><p class="muted small">번호는 이번 방송 안에서 고정돼요. 다른 손님의 주문은 보이지 않아요.</p></aside></div>`;
}
function lineList(lines,editable=false){return lines.map((l,i)=>{
 const current=productById(l.id),changed=current?.version!==l.version,available=current?.state==='published';
 const review=editable&&(changed||!available);
 return `<div class="request-line"><div class="list-line">${numberMark(l)}<div class="line-content"><strong><span class="muted">${l.number}</span> ${esc(l.name)}</strong><p>${esc(l.color)} · ${esc(l.size)}</p><span class="amount">${money(l.price*l.quantity)}</span>${productNotice(l)?`<p class="product-note">${productNotice(l)}</p>`:''}${!editable?`<span class="muted small"> · ${l.quantity}개</span>`:''}</div>${editable?`<div class="line-action">${button('−','quantity',`data-index="${i}" data-delta="-1" aria-label="${esc(l.name)} 수량 줄이기"`)}<span>${l.quantity}</span>${button('+','quantity',`data-index="${i}" data-delta="1" aria-label="${esc(l.name)} 수량 늘리기" ${l.quantity>=99||changed||!available?'disabled':''}`)}</div>`:''}</div>${review?`<div class="line-review">${available?productComparison(l,current):''}<div class="row wrap">${available?button('변경 내용 확인','review-product',`data-index="${i}" aria-label="${l.number}번 변경 내용 확인"`):''}${button('이 상품 빼기','remove-line',`data-index="${i}" aria-label="${l.number}번 상품 빼기"`,'quiet')}</div></div>`:''}</div>`;
 }).join('');}
function requestPage(){const g=guest();if(g.cancelled)return cancellationPanel(g);if(g.invoice)return `<section class="panel stack"><h2>처음 접수한 구매 요청</h2><div class="notice info">아래는 접수 당시의 기록이에요. 제외된 상품과 현재 결제할 금액은 최신 청구서에서 확인해 주세요.</div>${lineList(g.savedLines)}${button('최신 청구서 확인','go-invoice','','primary full')}</section>`;if(!g.lines.length)return `<section class="panel empty"><div class="empty-mark" aria-hidden="true">＋</div><h2>마음에 드는 상품을 담아 주세요</h2><p class="muted">${g.saved?'상품을 모두 뺐어요. 기존 구매 요청을 취소하려면 아래에서 저장해 주세요.':'색상과 수량을 고르면 여기에 모아 볼 수 있어요.'}</p>${g.saved&&!state.closed?button('구매 요청 취소 저장','cancel-request','','full'):''}${button('방송 상품 보러 가기','go-catalog','','primary')}</section>`;
return `<div class="customer-layout"><section class="panel"><div class="section-title"><h2>선택한 상품</h2><span class="tag ${g.saved&&!g.dirty?'green':'neutral'}">${g.saved&&!g.dirty?'구매 요청 저장됨':'아직 저장 전'}</span></div>${lineList(g.lines,!state.closed&&!g.invoice)}<div class="bill-row total"><span>${validateLines(g)?'변경 확인 전 합계':'상품 예상 합계'}</span><span class="amount">${money(total(g.lines))}</span></div><p class="muted small push">확보 수량과 배송비를 확인한 뒤 최종 청구서를 보내드려요. 지금은 송금하지 마세요.</p></section><aside class="panel stack">${state.closed?`<h2>이번 방송 요청이 마감됐어요</h2><p class="muted">저장한 요청을 기준으로 상품을 확인하고 있어요.</p>${button('배송지·청구서 확인','go-invoice','','primary full')}`:`<form id="request-form" class="stack"><h2>${g.saved?'구매 요청 수정':'누구의 주문인지 알려주세요'}</h2><label class="field">방송 닉네임<input name="nickname" maxlength="40" placeholder="방송에서 쓰는 닉네임" value="${esc(g.nickname)}" required><span class="hint">판매자가 알아볼 수 있는 이름</span></label><label class="field">연락받을 위챗 ID<input name="contact" maxlength="80" placeholder="위챗 ID 입력" value="${esc(g.contact)}" required><span class="hint">청구서 안내와 주문 복구에 사용해요.</span></label>${g.saved?'':`<label class="check"><input name="privacy" type="checkbox" required><span>주문 안내를 위해 닉네임과 연락처를 사용하는 데 동의해요. <span class="muted small">(시안 문구)</span></span></label>`}${validateLines(g)?`<div class="notice error" role="status">${validateLines(g)}</div>`:''}<button class="primary full" ${(g.saved&&!g.dirty)||validateLines(g)?'disabled':''}>${g.saved?'변경 내용 저장':'구매 요청 저장'}</button><p class="small muted">회원가입 없이 진행해요. 저장 후 더우인으로 직접 돌아가 주세요.</p></form>${g.saved?button('방송 후 배송지 입력','go-invoice','','full'):''}`}</aside></div>`;}
function addressForm(g){return `<form id="address-form" class="panel stack"><div><p class="section-kicker">방송 후 한 번만 입력</p><h2>중국 배송지를 알려주세요</h2></div><div class="fields two"><label class="field">받는 사람<input name="recipient" placeholder="수취인 이름" required></label><label class="field">전화번호 (+86)<input name="phone" type="tel" placeholder="중국 휴대폰 번호" required></label><label class="field">성 / 자치주<input name="province" placeholder="예: 吉林省" required></label><label class="field">시 / 구<input name="city" placeholder="예: 延吉市 · …" required></label></div><label class="field">상세주소<textarea name="detail" placeholder="도로명, 건물, 동·호수" required></textarea></label><button class="primary">배송지 저장</button><p class="muted small">현재는 시안입니다. 실제 개인 주소 대신 예시 값을 입력해 주세요.</p></form>`;}
function invoicePage(){const g=guest();if(g.cancelled)return cancellationPanel(g);if(!g.saved)return `<section class="panel empty"><div class="empty-mark" aria-hidden="true">≡</div><h2>구매 요청을 먼저 저장해 주세요</h2><p class="muted">방송 후 수량과 배송비가 확정되면 청구서를 볼 수 있어요.</p>${button('상품 고르기','go-catalog','','primary')}<div class="demo-inline push">빠르게 결제 화면만 검토하려면<br>${button('시안: 청구서 예시 불러오기','seed','','push')}</div></section>`;
if(!g.invoice)return `<div class="customer-layout"><section class="stack"><div class="notice info"><strong>최종 청구서를 준비하고 있어요.</strong><br>판매자가 확보 수량과 배송비를 확인한 뒤 안내해 드립니다.</div>${g.address?`<div class="panel stack"><h2>배송지가 저장됐어요</h2><p>${esc(g.address.province)} · ${esc(g.address.city)}</p><p class="muted small">${esc(g.address.recipient.slice(0,1))}** · 연락처 끝 ${esc(g.address.phone.slice(-4))}</p><p class="muted small">전체 주소는 배송 담당자에게만 전달됩니다.</p></div>`:addressForm(g)}</section><aside class="panel stack"><h3>구매 요청 ${state.guest}-0913</h3>${lineList(g.savedLines)}<div class="bill-row"><span>상품 예상 합계</span><strong>${money(total(g.savedLines))}</strong></div><p class="muted small">배송비는 아직 포함되지 않았어요.</p><div class="demo-inline">상단 ‘방송 담당자’에서 요청을 마감하고 청구서를 발행할 수 있어요.</div></aside></div>`;
const inv=g.invoice;
return `<div class="customer-layout"><section class="panel"><div class="bill-head"><div class="row between"><span class="eyebrow">YOUR ORDER</span><span class="tag ${inv.payment==='confirmed'?'green':'blue'}">${statusText(g)}</span></div><h2>${esc(g.nickname)}님의 청구서</h2><p class="muted small">OM-0913-${state.guest} · ${inv.revision}차 청구서</p></div>${invoiceChanges(inv)}${invoiceLines(g)}<div class="push"><div class="bill-row"><span>상품 금액</span><span>${money(total(inv.lines))}</span></div><div class="bill-row"><span>중국 배송비</span><span>${money(inv.shipping)}</span></div><div class="bill-row total"><strong>${inv.changeRequest?'처리 전 청구 금액':'최종 송금 금액'}</strong><span class="amount">${money(inv.total)} <span class="small muted">CNY</span></span></div></div><hr class="divider"><p class="muted small">배송지 · ${esc(g.address.province)} ${esc(g.address.city)}<br>수취인 ${esc(g.address.recipient.slice(0,1))}**</p>${inv.payment==='confirmed'?`<div class="progress-list"><div class="progress-item done"><strong>입금 확인 완료</strong>실제 수취 내역을 확인했어요.</div><div class="progress-item ${inv.shipped?'done':'current'}"><strong>${inv.shipped?'상품 발송 완료':'상품 준비 중'}</strong>${inv.shipped?'예시 택배 · DEMO-0913':'발송하면 배송 정보를 여기에 알려드려요.'}</div></div>`:''}${invoiceHistory(g)}</section><aside class="stack">${invoiceDecision(g)}</aside></div>`;
}
function sampleReceipt(g){return `<div class="receipt-preview"><span class="tag neutral">검토용 가상 거래 내역</span>${g.evidence?.url?`<img src="${esc(g.evidence.url)}" alt="선택한 송금 증빙 미리보기">`:`<span class="ok" aria-hidden="true">✓</span><strong>송금 완료 화면 예시</strong><span class="receipt-amount">${money(g.invoice.total)}</span><div class="bill-row"><span>받는 사람</span><span>샘플옷장 셀러 (가상)</span></div><div class="bill-row"><span>송금 수단</span><span>${g.method==='wechat'?'위챗페이':'알리페이'}</span></div><div class="bill-row"><span>거래 시각</span><span>2026-09-13 21:10</span></div><div class="bill-row"><span>거래번호</span><span>DEMO-${state.role==='collector'?state.reviewGuest:state.guest}-0913</span></div>`}<p class="small muted">첨부 자료만으로 입금이 확정되지 않아요.</p></div>`;}
function paymentPanel(g){const inv=g.invoice;
 if(inv.payment==='confirmed')return `<div class="panel stack"><span class="tag green">입금 확인 완료</span><h2>입금이 확인됐어요</h2><p>상품을 준비하고 있어요. 같은 청구서로 다시 송금하지 마세요.</p><div class="bill-row total"><span>확인 금액</span><strong>${money(inv.total)}</strong></div></div>`;
 if(inv.payment==='pending_review')return `<div class="panel stack"><span class="tag blue">입금 확인 대기</span><h2>확인 요청을 보냈어요</h2><p class="muted">판매자가 실제 수취 내역을 확인하고 있어요. 확인되면 이 화면에 표시됩니다.</p>${sampleReceipt(g)}<p class="muted small">추가 송금하지 말고 확인 결과를 기다려 주세요.</p></div>`;
 return `<div class="panel stack">${inv.payment==='unpaid'?button('송금 전 청구 수정 요청','request-invoice-change',g.upload!=='empty'?'disabled':'','quiet full'):''}<h2>${inv.payment==='needs_info'?'입금 내역을 더 확인할게요':'송금 방법 선택'}</h2>${inv.payment==='needs_info'?`<div class="notice error">${esc(g.reviewReason)}</div>`:''}<div class="method-options">${['wechat','alipay'].map(m=>`<button data-action="method" data-method="${m}" aria-pressed="${g.method===m}"><span class="wallet-icon ${m==='alipay'?'ali':''}">${m==='wechat'?'W':'支'}</span>${m==='wechat'?'위챗페이':'알리페이'}</button>`).join('')}</div><div class="notice"><strong>샘플옷장 셀러에게 ${money(inv.total)}</strong><br>판매자와 기존에 사용하던 송금 경로로 보내 주세요.<p class="small push">시안에서는 실제 수취 계정과 QR을 제공하지 않습니다.</p></div><div><h3>송금 내역을 첨부해 주세요</h3><p class="muted small push">금액·받는 사람·시각·완료 상태가 보이는 해당 거래의 캡처를 올려 주세요. 다른 거래와 잔액은 가려도 괜찮아요.</p></div><div class="upload"><label class="field">송금 내역 캡처<input id="receipt-file" type="file" accept="image/png,image/jpeg,image/webp" ${g.upload==='uploading'?'disabled':''}></label><div class="upload-state ${g.upload==='error'?'danger-text':''}" role="status">${g.upload==='empty'?'PNG · JPG · WebP / 8MB 이하':g.upload==='uploading'?'첨부를 저장하고 있어요…':g.upload==='ready'?`✓ ${esc(g.evidence.name)} · 첨부 저장 완료`:`첨부 실패 · ${esc(g.uploadError)}`}</div>${g.upload==='ready'?button('첨부 삭제','remove-evidence','','quiet full push'):''}${g.upload==='error'&&g.evidence?button('첨부 다시 저장','retry-upload','','full push'):''}</div><div class="demo-inline"><div class="row wrap">${button('예시 증빙 사용','sample-evidence',g.upload==='uploading'?'disabled':'')}<label class="check"><input id="fail-upload" type="checkbox">실패 상황 체험</label></div><p>실제 파일도 기기 안에서만 미리 봅니다. 외부 전송은 없습니다.</p></div>${button(inv.payment==='needs_info'?'보완 후 입금 확인 요청':'입금 확인 요청','submit-payment',g.upload!=='ready'?'disabled':'','primary full')}<p class="muted small">첨부 저장이 완료돼야 요청할 수 있어요. 이 버튼은 입금 완료 버튼이 아닙니다.</p><details><summary>캡처를 첨부하기 어려워요</summary><p class="muted small push">판매자에게 거래번호·송금자·금액·시각을 알려 수취 내역 대조를 요청해 주세요. 거래정보 제출 양식은 후속 구현 범위입니다.</p></details></div>`;
}
function productFields(p=null){
 const locked=Boolean(p?.everOrdered);
 return `<label class="field">상품 이름<input name="name" placeholder="예: 라운드 니트" maxlength="60" required value="${esc(p?.name||'')}"></label><label class="field">가격 (CNY)<input name="price" type="number" min="0.01" step="0.01" placeholder="88.00" required value="${p?(p.price/100).toFixed(2):''}"></label><details class="option-details"><summary>색상·사이즈 선택 목록 ${locked?'(주문 이력 있어 변경 불가)':'미리 지정 (선택)'}</summary><div class="fields push"><label class="field">색상 목록<input name="colors" placeholder="예: 화이트, 블랙" maxlength="100" value="${esc(p?.colors.join(', ')||'')}" ${locked?'disabled':''}></label><label class="field">사이즈 목록<input name="sizes" placeholder="예: M, L 또는 FREE" maxlength="80" value="${esc(p?.sizes.join(', ')||'')}" ${locked?'disabled':''}></label><p class="small muted">비워두면 손님이 원하는 색상·사이즈를 직접 적어요. 방송 후 공급 가능한 옵션을 확인합니다.</p></div></details>`;
}
function staffProduct(p){
 return `<article class="staff-product">${numberMark(p)}<div class="info"><strong>${esc(p.name)}</strong><p>${money(p.price)} · ${p.colors.length?p.colors.map(esc).join(', '):'손님이 옵션 입력'}</p><span class="tag ${p.state==='paused'?'neutral':'green'}">${p.state==='paused'?'판매 중지':'게시됨'}</span>${p.everOrdered?'<span class="tag neutral">요청 접수됨 · 정보 고정</span><p class="product-note">이름·가격·옵션은 수정할 수 없어요. 정정이 필요하면 판매 중지 후 고객에게 확인해 주세요.</p>':''}</div><div class="staff-actions">${button('수정','edit-product',`data-id="${p.id}" ${state.closed||p.everOrdered?'disabled':''} aria-label="${p.number}번 상품 수정"`)}${p.state==='paused'?button('판매 재개','resume-product',`data-id="${p.id}" ${state.closed?'disabled':''} aria-label="${p.number}번 상품 판매 재개"`):button('판매 중지','manage-product',`data-id="${p.id}" data-operation="pause" ${state.closed?'disabled':''} aria-label="${p.number}번 상품 판매 중지"`)}${!p.everOrdered?button('삭제','manage-product',`data-id="${p.id}" data-operation="delete" ${state.closed?'disabled':''} aria-label="${p.number}번 상품 삭제"`,'danger-text'):''}</div></article>`;
}
function operator(){
 const saved=Object.entries(state.guests).filter(([,g])=>g.saved),visible=state.products.filter(p=>p.state!=='deleted'),deleted=state.products.filter(p=>p.state==='deleted');
 return `${header('셀러센터 · 방송 주문')}<main class="page"><div class="intro"><div><span class="eyebrow">SELLER WORKSPACE</span><h1>현장 방송 주문 관리</h1><p>9월 13일 · 샘플옷장 · CNY</p></div><span class="tag ${state.closed?'neutral':'green'}">${state.closed?'구매 요청 마감됨':'구매 요청 접수 중'}</span></div><div class="summary-banner"><div><strong>${state.closed?'방송 후 확보 수량과 청구서를 확인해 주세요.':'사진 없이, 이름과 가격만 등록하세요.'}</strong><p>${state.closed?'청구서를 발행하면 고객이 최종 금액을 확인하고 송금할 수 있어요.':'상품 번호는 자동으로 붙어요. 방송에서 번호를 함께 안내해 주세요.'}</p></div><div class="row wrap">${button(state.phase==='ordering'?'상품 소개로 전환':'주문 시간으로 전환','phase',state.closed?'disabled':'')}${button('구매 요청 마감','close-session',state.closed?'disabled':'','dark')}</div></div><section class="metrics"><div class="metric"><p>등록 상품</p><strong>${visible.length}<span class="small muted"> 개</span></strong></div><div class="metric"><p>요청한 손님</p><strong>${saved.filter(([,g])=>!g.cancelled).length}<span class="small muted"> 명</span></strong></div><div class="metric"><p>저장된 요청 수량</p><strong>${saved.reduce((n,[,g])=>n+(g.cancelled?0:count(g.savedLines)),0)}<span class="small muted"> 개</span></strong></div></section><div class="operator-layout"><div class="stack"><section class="panel"><div class="section-title"><h2>이번 방송 상품</h2><span class="small muted">번호는 바뀌지 않아요</span></div>${visible.map(staffProduct).join('')||'<p class="muted">첫 상품을 등록해 주세요.</p>'}${deleted.length?`<details class="push"><summary>삭제한 상품 ${deleted.length}개</summary>${deleted.map(p=>`<div class="deleted-product"><span>${p.number} · ${esc(p.name)}</span>${button('복구','restore-product',`data-id="${p.id}" ${state.closed?'disabled':''} aria-label="${p.number}번 상품 복구"`)}</div>`).join('')}</details>`:''}</section><section class="panel"><div class="section-title"><h2>손님별 요청·청구</h2><span class="small muted">${saved.length}건</span></div>${saved.length?saved.map(([id,g])=>staffRequest(id,g)).join(''):'<p class="muted">아직 저장된 구매 요청이 없습니다. 손님 화면에서 요청을 저장해 보세요.</p>'}</section></div><aside class="panel"><form id="product-form" class="stack"><div class="row between"><div><p class="section-kicker">현장에서 상품당 한 번</p><h2>상품 바로 등록</h2></div>${numberMark({number:String(state.nextProductNumber).padStart(2,'0')})}</div><fieldset class="product-fieldset stack" ${state.closed?'disabled':''}>${productFields()}<button class="primary full">상품 등록하고 게시</button></fieldset><p class="muted small">손님에게 “${String(state.nextProductNumber).padStart(2,'0')}번 상품”으로 안내해 주세요. 사진 촬영이나 첨부는 필요 없어요.</p></form></aside></div><p class="footer-note">구매 요청이 한 건이라도 접수되면 이름·가격·옵션과 삭제가 잠깁니다. 정정은 판매 중지 후 고객 확인을 거쳐 별도로 처리하세요.</p></main>`;
}
function editProduct(id){
 const p=productById(id);if(!p||p.state==='deleted'||state.closed)return;
 if(p.everOrdered)return notify('구매 요청이 접수된 상품은 수정할 수 없어요. 판매 중지 후 고객에게 정정 내용을 확인해 주세요.');
 const dialog=$('#manage-dialog');dialog.innerHTML=`<div class="dialog-heading"><h2 id="manage-title">${p.number}번 상품 수정</h2><button data-close="manage-dialog" aria-label="상품 수정 닫기">×</button></div><form id="edit-product-form" data-id="${p.id}" data-version="${p.version}" class="stack"><div class="notice">아직 접수된 구매 요청이 없어 수정할 수 있어요. 이미 담은 손님은 변경 내용을 확인해야 요청을 저장할 수 있어요.</div>${productFields(p)}<label class="field">수정 사유<input name="reason" placeholder="예: 가격 오타 수정" maxlength="120" required></label><button class="primary full">수정 내용 저장</button></form>`;dialog.showModal();
}
function manageProduct(id,operation){
 const p=productById(id);if(!p||p.state==='deleted'||state.closed)return;
 const deleting=operation==='delete';const dialog=$('#manage-dialog');
 if(deleting&&p.everOrdered)return notify('주문 이력이 있는 상품은 판매 중지를 사용해 주세요.');
 dialog.innerHTML=`<div class="dialog-heading"><h2 id="manage-title">${p.number}번 ${deleting?'상품 삭제':'판매 중지'}</h2><button data-close="manage-dialog" aria-label="상품 관리 닫기">×</button></div><p><strong>${esc(p.name)}</strong> · ${money(p.price)}</p><div class="notice">${deleting?'고객 목록에서 숨깁니다. 아직 저장하지 않은 장바구니에서도 새 요청할 수 없어요. 삭제한 상품에서 복구할 수 있으며, 번호를 다른 상품에 다시 쓰지 않습니다.':'새 구매 요청을 중지합니다. 이미 저장된 요청과 청구서는 그대로 남고, 취소가 필요하면 고객별로 별도 처리합니다.'}</div><form id="manage-product-form" data-id="${p.id}" data-operation="${operation}" data-version="${p.version}" class="stack push"><label class="field">${deleting?'삭제':'중지'} 사유<input name="reason" maxlength="120" required placeholder="예: 잘못 등록한 상품"></label><button class="${deleting?'dark':'primary'} full">${deleting?'고객 목록에서 삭제':'판매 중지하기'}</button></form>`;dialog.showModal();
}
function staffRequest(id,g){
 if(g.cancelled)return `<article class="guest-card"><h3>${esc(g.nickname)}</h3>${cancellationPanel(g)}</article>`;
 const inv=g.invoice;
 return `<article class="guest-card"><div class="title"><div><strong>${esc(g.nickname)}</strong><p class="small muted">${id}-0913 · ${count(g.savedLines)}개</p></div><span class="tag ${inv?.payment==='confirmed'?'green':'neutral'}">${statusText(g)}</span></div>${inv?`<div class="bill-row"><span>청구서 ${inv.revision}차</span><strong>${money(inv.total)}</strong></div>${inv.changeRequest?`<div class="notice error push"><strong>고객이 다시 확인해 달라고 요청했어요</strong><p>${esc(inv.changeRequest.reason)}</p>${requestedRemovalList(g)}<span class="small">미송금 확인됨 · 주문은 취소되지 않았어요</span></div>`:''}${inv.changeReason?`<p class="small muted push">정정 사유: ${esc(inv.changeReason)}</p>`:''}<p class="muted small push">${inv.payment!=='unpaid'?'송금 확인이 시작되어 청구 내용을 바꿀 수 없어요.':inv.accepted?'고객에게 송금 안내가 열려 있어요. 직접 정정은 잠겼어요.':inv.changeRequest?(allRemovalRequested(g)?'전체 제외 요청을 확인하고 주문 취소를 처리해 주세요.':'요청 내용을 확인하고 새 청구서를 준비해 주세요.'):'고객이 확인하면 송금 안내가 열려요.'}</p>${allRemovalRequested(g)?button('전체 주문 취소 확인','cancel-invoiced-request',`data-guest="${id}" aria-label="${esc(g.nickname)} 전체 주문 취소 확인"`,'full push'):button(removalKeys(g).length?'제외 요청 반영하기':'청구서 정정','edit-invoice',`data-guest="${id}" ${canReissue(g)?'':'disabled'} aria-label="${esc(g.nickname)} 청구서 정정"`,'full push')}${inv.payment==='confirmed'&&!inv.shipped?button('배송 정보 등록 (시안)','ship',`data-guest="${id}"`,'full push'):''}${invoiceHistory(g)}`:invoiceFields(id,g)}</article>`;
}
function collector(){const list=Object.entries(state.guests).filter(([,g])=>g.invoice&&g.invoice.payment!=='unpaid');if(!list.find(([id])=>id===state.reviewGuest)&&list.length)state.reviewGuest=list[0][0];const g=state.guests[state.reviewGuest];const confirmed=list.filter(([,x])=>x.invoice.payment==='confirmed').reduce((n,[,x])=>n+x.invoice.total,0);return `${header('수금 확인 · 셀러 직접 수금')}<main class="page"><div class="intro"><div><span class="eyebrow">PAYMENT REVIEW</span><h1>입금 확인</h1><p>고객의 증빙과 실제 수취 계정의 거래 내역을 대조해 주세요.</p></div><span class="tag neutral">샘플옷장 · 9월 13일</span></div><div class="summary-banner"><div><strong>이번 회차는 셀러가 직접 수금해요.</strong><p>확인한 판매대금을 플랫폼이 셀러에게 다시 지급하지 않습니다.</p></div><div><span class="small muted">확인된 직접 수금</span><strong class="amount"> ${money(confirmed)}</strong><p>플랫폼 지급 대상 ¥0.00</p></div></div>${list.length?`<div class="collector-layout"><aside class="panel"><h3>입금 확인 요청</h3>${list.map(([id,x])=>`<button class="review-pick" data-action="pick-review" data-guest="${id}" aria-pressed="${id===state.reviewGuest}"><div class="row between"><strong>${esc(x.nickname)}</strong><span class="amount">${money(x.invoice.total)}</span></div><span class="small">OM-0913-${id}</span><span class="tag ${x.invoice.payment==='confirmed'?'green':'blue'}">${statusText(x)}</span></button>`).join('')}</aside><section class="panel"><div class="section-title"><h2>${esc(g.nickname)}님의 확인 요청</h2><span class="tag blue">${statusText(g)}</span></div><div class="review-main"><div class="stack"><h3>고객이 첨부한 자료</h3>${sampleReceipt(g)}${g.history.length?`<p class="small muted">이전 확인 이력 ${g.history.length}건 · ${esc(g.history[g.history.length-1])}</p>`:''}</div><div class="stack"><h3>청구서 대조 정보</h3><div><div class="bill-row"><span>청구 금액</span><strong>${money(g.invoice.total)} CNY</strong></div><div class="bill-row"><span>수단</span><span>${g.method==='wechat'?'위챗페이':'알리페이'}</span></div><div class="bill-row"><span>수취인</span><span>샘플옷장 셀러 (가상)</span></div></div><div class="notice">고객의 캡처와 별도로, 실제 수취 계정에서 거래 완료 여부를 확인하세요.</div>${g.invoice.payment==='pending_review'?`<form id="review-form" class="stack"><label class="field">실제로 수취한 금액 (CNY)<input name="actual" type="number" min="0.01" step="0.01" required placeholder="수취 내역의 금액"></label><label class="field">수취 내역의 거래 식별자<input name="reference" required maxlength="100" placeholder="예: DEMO-RECEIPT-001"></label><label class="check"><input id="ledger-checked" name="checked" type="checkbox" required><span>실제 수취 계정에서 금액·수취인·시각·완료 상태를 대조했습니다.</span></label><button id="confirm-payment" class="primary full" disabled>입금 확인 완료로 처리</button></form>`:`<div class="notice ${g.invoice.payment==='confirmed'?'good':'info'}">${g.invoice.payment==='confirmed'?'수취 내역 확인을 마쳤습니다.':esc(g.reviewReason)}</div>`}</div></div>${g.invoice.payment==='pending_review'?`<form id="needs-info-form" class="review-controls stack"><label class="field">대조가 어려울 때 고객에게 요청할 내용<textarea name="reason" placeholder="예: 받는 사람과 송금 시각이 보이는 화면을 다시 첨부해 주세요." required maxlength="300"></textarea></label><button>추가 확인 요청 보내기</button></form>`:''}</section></div>`:`<section class="panel empty"><div class="empty-mark" aria-hidden="true">✓</div><h2>아직 입금 확인 요청이 없어요</h2><p class="muted">고객이 청구서를 확인하고 증빙을 제출하면 여기에 표시돼요.</p><div class="demo-inline">손님 화면 → 청구·입금 → 청구서 예시 불러오기로 체험할 수 있어요.</div></section>`}</main>`;}
function showProduct(id,replaceIndex=null){
 const p=productById(id);if(!p||p.state!=='published'||state.closed)return;
 const previous=replaceIndex===null?null:guest().lines[replaceIndex];
 if(replaceIndex!==null&&(!previous||previous.id!==p.id))return;
 const dialog=$('#product-dialog');dialog.innerHTML=`<div class="dialog-heading"><h2 id="product-dialog-title">${previous?'변경된 상품 확인':'상품 옵션 선택'}</h2><button data-close="product-dialog" aria-label="상품 선택 닫기">×</button></div><div class="dialog-product">${numberMark(p,true)}<div><span class="tag neutral">상품 ${p.number}</span><h3>${esc(p.name)}</h3><span class="amount">${money(p.price)}</span></div></div>${previous?`<div class="notice"><strong>담은 내용이 달라졌어요</strong>${productComparison(previous,p)}<p class="small">이전에 고른 옵션: ${esc(previous.color)} · ${esc(previous.size)}<br>아래에서 현재 옵션을 확인하고 다시 골라 주세요.</p></div>`:''}<form id="choose-form" data-id="${p.id}" data-version="${p.version}" ${previous?`data-replace-index="${replaceIndex}" data-previous-version="${previous.version}"`:''} class="stack">${p.colors.length?`<label class="field">색상<select name="color" required><option value="">선택해 주세요</option>${p.colors.map(x=>`<option>${esc(x)}</option>`).join('')}</select></label>`:'<label class="field">원하는 색상 (선택)<input name="color" maxlength="40" placeholder="예: 빨간색 · 비워두면 방송 소개 색상"></label>'}${p.sizes.length?`<label class="field">사이즈<select name="size" required>${p.sizes.length>1||previous?'<option value="">선택해 주세요</option>':''}${p.sizes.map(x=>`<option>${esc(x)}</option>`).join('')}</select></label>`:'<label class="field">원하는 사이즈 (선택)<input name="size" maxlength="40" placeholder="예: L · 필요한 경우 입력"></label>'}<label class="field">수량<input name="quantity" type="number" min="1" max="99" value="${previous?.quantity||1}" required></label><button class="primary full">${previous?'변경 내용 확인하고 담기':'내 구매 요청에 담기'}</button><p class="small muted">직접 적은 옵션은 방송 후 판매자가 공급 가능 여부를 확인해요.</p></form>`;dialog.showModal();
}
function simulateUpload(g,evidence,fail){
 releaseEvidence(g);g.evidence=evidence;g.upload='uploading';const ticket=++uploadCounter;g.uploadTicket=ticket;render();
 setTimeout(()=>{if(g.uploadTicket!==ticket||!g.evidence)return;g.upload=fail?'error':'ready';g.uploadError=fail?'연결이 끊겼어요. 선택한 첨부를 다시 저장해 주세요.':'';render();},650);
}
function seed(){const g=guest();releaseEvidence(g);g.nickname=`예시손님 ${state.guest}`;g.contact=`demo-only-${state.guest}`;g.lines=[{...initialState().products[0],color:'아이보리',size:'FREE',quantity:2}];g.savedLines=clone(g.lines);if(productById(g.lines[0].id))productById(g.lines[0].id).everOrdered=true;g.saved=true;g.dirty=false;g.address={recipient:'예시손님',phone:'00000000000',province:'吉林省',city:'延吉市',detail:'시안 주소'};g.invoice=buildInvoice(g,g.savedLines.map(l=>({...l,requested:l.quantity,requestedPrice:l.price})),1200,'');g.invoiceHistory=[];state.closed=true;render();notify('가상 청구서를 불러왔어요. 실제 송금은 하지 마세요.');}
document.addEventListener('click',(event)=>{
 const b=event.target.closest('button');if(!b||b.disabled)return;
 if(b.dataset.close){document.getElementById(b.dataset.close).close();return;}
 if(b.dataset.role){state.role=b.dataset.role;render();return;}
 if(b.dataset.page){state.page=b.dataset.page;render();return;}
 if(b.id==='reset-demo'){Object.values(state.guests).forEach(releaseEvidence);state=initialState();render();notify('시안을 처음 상태로 되돌렸어요.');return;}
 const g=guest();switch(b.dataset.action){
 case 'help':$('#help-dialog').showModal();break;
 case 'go-catalog':state.page='catalog';render();break;
 case 'go-request':state.page='request';render();break;
 case 'go-invoice':state.page='invoice';render();break;
 case 'product':showProduct(b.dataset.id);break;
 case 'review-product':{const i=Number(b.dataset.index);if(!state.closed&&!g.invoice&&g.lines[i])showProduct(g.lines[i].id,i);break;}
 case 'remove-line':if(!state.closed&&!g.invoice){g.lines.splice(Number(b.dataset.index),1);g.dirty=true;render();}break;
 case 'edit-product':editProduct(b.dataset.id);break;
 case 'manage-product':manageProduct(b.dataset.id,b.dataset.operation);break;
 case 'restore-product':{const p=productById(b.dataset.id);if(!state.closed&&p?.state==='deleted'){p.state='paused';p.version++;render();notify('판매 중지 상태로 복구했어요. 내용을 확인한 뒤 판매 재개를 눌러 주세요.');}break;}
 case 'resume-product':{const p=productById(b.dataset.id);if(!state.closed&&p?.state==='paused'){p.state='published';p.version++;render();notify('판매를 재개했어요. 기존 상품 번호를 유지합니다.');}break;}
 case 'quantity':{if(state.closed||g.invoice)return;const i=Number(b.dataset.index);const q=g.lines[i].quantity+Number(b.dataset.delta);const p=productById(g.lines[i].id);if(Number(b.dataset.delta)>0&&(!p||p.state!=='published'||p.version!==g.lines[i].version)){notify('이 상품은 변경되거나 판매 중지됐어요. 기존 수량을 늘릴 수 없습니다.');return;}if(q<=0)g.lines.splice(i,1);else if(q<=99)g.lines[i].quantity=q;g.dirty=true;render();break;}
 case 'cancel-request':if(!state.closed&&!g.invoice&&g.saved&&!g.lines.length){g.saved=false;g.savedLines=[];g.dirty=false;render();notify('구매 요청을 취소했어요.');}break;
 case 'seed':seed();break;
 case 'seed-correction':seedCorrection();break;
 case 'seed-exclusion':seedExclusion();break;
 case 'request-line-removal':requestInvoiceChange(Number(b.dataset.index));break;
 case 'exclude-invoice-line':toggleInvoiceExclusion(b);break;
 case 'cancel-invoiced-request':confirmInvoiceCancellation(b.dataset.guest);break;
 case 'edit-invoice':editInvoice(b.dataset.guest);break;
 case 'request-invoice-change':requestInvoiceChange();break;
 case 'phase':if(!state.closed){state.phase=state.phase==='ordering'?'introducing':'ordering';render();notify('고객 화면의 안내를 바꿨어요. 상품 선택은 유지돼요.');}break;
 case 'close-session':state.closed=true;Object.values(state.guests).forEach(x=>{x.lines=clone(x.savedLines);x.dirty=false;});render();notify('구매 요청을 마감했어요. 저장된 요청으로 청구서를 준비하세요.');break;
 case 'method':if(g.invoice&&['unpaid','needs_info'].includes(g.invoice.payment)){g.method=b.dataset.method;releaseEvidence(g);render();}break;
 case 'sample-evidence':simulateUpload(g,{name:'송금내역_예시.png',url:null},$('#fail-upload').checked);break;
 case 'remove-evidence':releaseEvidence(g);render();break;
 case 'retry-upload':{const evidence=g.evidence;g.evidence=null;simulateUpload(g,evidence,false);break;}
 case 'submit-payment':if(g.upload==='ready'&&g.invoice?.accepted&&['unpaid','needs_info'].includes(g.invoice.payment)){g.invoice.payment='pending_review';g.history.push('증빙 첨부 후 확인 요청');render();notify('입금 확인 요청을 보냈어요. 실제 입금 확정은 아직이에요.');}break;
 case 'pick-review':state.reviewGuest=b.dataset.guest;render();break;
 case 'ship':{const x=state.guests[b.dataset.guest];if(x.invoice?.payment==='confirmed'){x.invoice.shipped=true;render();notify('예시 배송 정보를 등록했어요.');}break;}
 }
});
document.addEventListener('input',(event)=>{
 const form=event.target.closest('.invoice-form');if(!form)return;
 if(!['reviewed','shipping-reviewed'].includes(event.target.name)){form.querySelector('[name=reviewed]').checked=false;form.querySelector('[name=shipping-reviewed]').checked=false;}
 updateInvoiceDraft(form);
});
document.addEventListener('change',(event)=>{
 const el=event.target;
 if(el.name==='remove-line'){
  const form=el.closest('#invoice-change-form'),selected=form.querySelectorAll('[name=remove-line]:checked').length;
  form.querySelector('.removal-confirm').hidden=!selected;form.querySelector('[name=confirm-removal]').required=selected>0;form.querySelector('[name=confirm-removal]').checked=false;
  form.querySelector('.removal-submit').textContent=selected?'상품 제외 요청 남기기':'수정 요청 남기기';
 }

 if(el.id==='demo-guest'){state.guest=el.value;render();notify(`손님 ${state.guest}의 화면이에요. 공용 상품 목록은 같고 구매 요청은 분리돼요.`);}
 if(el.id==='ledger-checked')$('#confirm-payment').disabled=!el.checked;
 if(el.id==='receipt-file'){
  const file=el.files[0];if(!file)return;const g=guest();
  if(!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size>8*1024*1024){releaseEvidence(g);g.upload='error';g.uploadError='8MB 이하 PNG·JPG·WebP 이미지를 선택해 주세요.';render();return;}
  simulateUpload(g,{name:file.name,url:URL.createObjectURL(file)},$('#fail-upload').checked);
 }
});
document.addEventListener('input',(event)=>{if(event.target.closest('#request-form')&&['nickname','contact'].includes(event.target.name)){guest()[event.target.name]=event.target.value;guest().dirty=true;const save=$('#request-form button');if(save)save.disabled=false;}});
document.addEventListener('submit',(event)=>{
 event.preventDefault();const form=event.target;if(!form.reportValidity())return;const data=new FormData(form);const g=guest();
 if(form.id==='choose-form'){
  if(state.closed)return notify('구매 요청이 마감됐어요.');
  const p=productById(form.dataset.id);
  if(!p||p.state!=='published'||p.version!==Number(form.dataset.version))return notify('상품 정보가 변경됐어요. 닫고 다시 선택해 주세요.');
  const color=String(data.get('color')||'').trim()||'방송 소개 색상',size=String(data.get('size')||'').trim()||'별도 사이즈 요청 없음',quantity=Number(data.get('quantity'));
  if(!Number.isInteger(quantity)||quantity<1||quantity>99)return notify('수량은 1~99개로 입력해 주세요.');
  const replaceIndex=form.dataset.replaceIndex===undefined?null:Number(form.dataset.replaceIndex);
  const previous=replaceIndex===null?null:g.lines[replaceIndex];
  if(replaceIndex!==null&&(!previous||previous.id!==p.id||previous.version!==Number(form.dataset.previousVersion)))return notify('담은 내용이 바뀌었어요. 닫고 다시 확인해 주세요.');
  const line=g.lines.find((x,i)=>i!==replaceIndex&&x.id===p.id&&x.color===color&&x.size===size);
  if(line&&line.version!==p.version)return notify('같은 옵션으로 담은 상품에도 변경 내용이 있어요. 내 구매 요청에서 먼저 확인해 주세요.');
  if(line&&line.quantity+quantity>99)return notify('한 옵션의 수량은 99개까지 선택할 수 있어요.');
  if(line){line.quantity+=quantity;if(previous)g.lines.splice(replaceIndex,1);}
  else if(previous)g.lines[replaceIndex]={...p,color,size,quantity};
  else g.lines.push({...p,color,size,quantity});
  g.dirty=true;$('#product-dialog').close();render();notify(previous?'변경 내용을 확인해 담았어요. 구매 요청 저장을 눌러 접수해 주세요.':'담았어요. 내 구매 요청에서 저장해 주세요.');
 }else if(form.id==='request-form'){
  if(state.closed||!g.lines.length)return;const issue=validateLines(g);if(issue)return notify(issue);g.nickname=String(data.get('nickname')).trim();g.contact=String(data.get('contact')).trim();if(!g.nickname||!g.contact)return notify('닉네임과 연락받을 위챗 ID를 입력해 주세요.');g.lines.forEach(l=>{productById(l.id).everOrdered=true;});g.savedLines=clone(g.lines);g.saved=true;g.dirty=false;render();notify('구매 요청이 저장됐어요. 이제 더우인으로 돌아가셔도 돼요.');
 }else if(form.id==='address-form'){
  const address=Object.fromEntries(data);if(Object.values(address).some(x=>!String(x).trim()))return notify('배송지의 빈 항목을 입력해 주세요.');g.address=address;render();notify('배송지가 저장됐어요. 최종 청구서를 기다려 주세요.');
 }else if(form.id==='accept-form'){
  if(!g.invoice||g.cancelled||g.invoice.changeRequest||g.invoice.payment!=='unpaid'||g.invoice.revision!==Number(form.dataset.revision)||!data.get('agree'))return notify('청구 내용이 바뀌었어요. 최신 청구서를 다시 확인해 주세요.');
  g.invoice.accepted=true;render();notify('최종 청구 내용을 확인했어요.');
 }else if(form.id==='invoice-change-form'){
  const inv=g.invoice,reason=String(data.get('reason')||'').trim();
  if(!canRequestChange(g)||inv.revision!==Number(form.dataset.revision)||!data.get('not-transferred')||!reason)return notify('청구 상태와 미송금 확인을 다시 확인해 주세요.');
  const indices=data.getAll('remove-line').map(Number);
  if(new Set(indices).size!==indices.length||indices.some(i=>!Number.isInteger(i)||!inv.lines[i]||inv.lines[i].excluded)||(indices.length&&!data.get('confirm-removal')))return notify('제외할 상품과 확인 항목을 확인해 주세요.');
  inv.changeRequest={id:`change-${state.guest}-${inv.revision}`,kind:indices.length?'remove_items':'adjustment',confirmedRemoval:indices.length>0,cancelIfAllCurrentItemsRemoved:indices.length>0,removeLineKeys:indices.map(i=>lineKey(inv.lines[i])),reason,notTransferred:true,previouslyAccepted:inv.accepted};inv.accepted=false;releaseEvidence(g);$('#manage-dialog').close();render();notify(allRemovalRequested(g)?'전체 제외 요청을 남겼어요. 담당자의 취소 확인을 기다려 주세요.':removalKeys(g).length?'상품 제외 요청을 남겼어요. 새 청구서를 확인할 때까지 송금하지 마세요.':'수정 요청을 남겼어요. 새 청구서를 확인할 때까지 송금하지 마세요.');
 }else if(form.id==='product-form'||form.id==='edit-product-form'){
  if(state.closed)return;
  const existing=form.id==='edit-product-form'?productById(form.dataset.id):null;
  if(form.id==='edit-product-form'&&(!existing||existing.state==='deleted'||existing.version!==Number(form.dataset.version)))return notify('상품 정보가 바뀌었어요. 다시 열어 확인해 주세요.');
  if(existing?.everOrdered)return notify('구매 요청이 접수되어 수정이 잠겼어요. 판매 중지 후 정정 내용을 고객에게 확인해 주세요.');
  const name=String(data.get('name')).trim(),price=Math.round(Number(data.get('price'))*100);
  const colors=String(data.get('colors')||'').split(',').map(x=>x.trim()).filter(Boolean);
  const sizes=String(data.get('sizes')||'').split(',').map(x=>x.trim()).filter(Boolean);
  if(!name||!Number.isSafeInteger(price)||price<=0)return notify('이름과 가격을 확인해 주세요.');
  if(existing){const reason=String(data.get('reason')||'').trim();if(!reason)return notify('수정 사유를 적어 주세요.');Object.assign(existing,{name,price,colors,sizes,version:existing.version+1,lastReason:reason});$('#manage-dialog').close();render();notify('상품을 수정했어요. 이미 담은 손님은 변경 내용을 확인해야 접수할 수 있어요.');}
  else{const n=state.nextProductNumber++;state.products.push({id:`p-${n}`,number:String(n).padStart(2,'0'),name,price,colors,sizes,version:1,state:'published',everOrdered:false});render();notify(`${String(n).padStart(2,'0')}번 상품을 게시했어요. 방송에서 번호를 안내해 주세요.`);}
 }else if(form.id==='manage-product-form'){
  const p=productById(form.dataset.id),reason=String(data.get('reason')||'').trim();if(!p||state.closed||p.version!==Number(form.dataset.version)||!reason)return;
  if(form.dataset.operation==='delete'&&p.everOrdered)return notify('주문 이력이 생겼어요. 삭제 대신 판매 중지를 사용해 주세요.');
  p.state=form.dataset.operation==='delete'?'deleted':'paused';p.version++;p.lastReason=reason;$('#manage-dialog').close();render();notify(p.state==='deleted'?'고객 목록에서 삭제했어요. 상품 번호는 다시 사용하지 않아요.':'판매를 중지했어요. 이미 저장된 요청은 유지됩니다.');
 }else if(form.classList.contains('invoice-form')){
  const x=state.guests[form.dataset.guest],old=x.invoice;
  if(state.role!=='operator'||!state.closed||!x.address||x.cancelled)return;
  if(old&&(!canReissue(x)||old.revision!==Number(form.dataset.revision)||(old.changeRequest?.id||'')!==form.dataset.changeId))return notify('고객 요청이나 송금 상태가 바뀌었어요. 다시 열어 확인해 주세요.');
  if(!old&&Number(form.dataset.revision)!==0)return;
  const shipping=Math.round(Number(data.get('shipping'))*100),reason=String(data.get('reason')||'').trim();
  const lines=x.savedLines.map((l,i)=>{const previous=old?.lines.find(v=>lineKey(v)===lineKey(l)),excluded=data.get(`exclude-${i}`)==='1';return {...l,requested:l.quantity,requestedPrice:l.price,quantity:Number(data.get(`qty-${i}`)),price:Math.round(Number(data.get(`price-${i}`))*100),excluded,exclusionReason:excluded?(previous?.exclusionReason||reason):null};});
  if(lines.some(l=>!Number.isInteger(l.quantity)||l.quantity>l.requested||(l.excluded?l.quantity!==0:l.quantity<1)||!Number.isSafeInteger(l.price)||l.price<=0)||!Number.isSafeInteger(shipping)||shipping<0)return notify('확보 수량·단가·배송비를 확인해 주세요.');
  if(lines.some(l=>old?.lines.find(v=>lineKey(v)===lineKey(l))?.excluded&&!l.excluded))return notify('이미 제외한 상품을 다시 청구할 수 없어요.');
  if(!lines.some(l=>!l.excluded))return notify('전부 제외하면 고객의 전체 제외 요청 확인 후 주문 취소로 처리해 주세요.');
  if(removalKeys(x).some(key=>!lines.find(l=>lineKey(l)===key)?.excluded))return notify('고객이 제외 요청한 상품을 청구에서 제외해 주세요.');
  const newExclusion=lines.some(l=>l.excluded&&!old?.lines.find(v=>lineKey(v)===lineKey(l))?.excluded);
  if(newExclusion&&!data.get('shipping-reviewed'))return notify('남은 상품 기준으로 배송비를 확인해 주세요.');
  if((old||lines.some(l=>l.excluded||l.price!==l.requestedPrice||l.quantity!==l.requested))&&!reason)return notify('고객이 이해할 수 있도록 변경 사유를 적어 주세요.');
  if(!data.get('reviewed'))return;
  const next=buildInvoice(x,lines,shipping,reason);
  if(!Number.isSafeInteger(next.total))return notify('청구 금액을 확인해 주세요.');
  if(old)x.invoiceHistory.push(clone(old));
  lines.filter(l=>l.price!==l.requestedPrice).forEach(l=>{const product=productById(l.id);if(product&&product.state!=='paused'){product.state='paused';product.version++;}});
  releaseEvidence(x);x.invoice=next;$('#manage-dialog').close();render();notify(old?'새 청구서를 발행했어요. 제외 내역과 남은 금액을 고객이 다시 확인해야 해요.':'청구서를 발행했어요. 고객의 확인을 기다립니다.');
 }else if(form.id==='cancel-invoiced-form'){
  const x=state.guests[form.dataset.guest],inv=x?.invoice,reason=String(data.get('reason')||'').trim();
  if(state.role!=='operator'||!inv||x.cancelled||!allRemovalRequested(x)||inv.accepted||inv.payment!=='unpaid'||x.upload!=='empty'||inv.revision!==Number(form.dataset.revision)||inv.changeRequest?.id!==form.dataset.changeId||!inv.changeRequest.notTransferred||!inv.changeRequest.confirmedRemoval||!inv.changeRequest.cancelIfAllCurrentItemsRemoved||!data.get('verified')||!reason)return notify('고객의 전체 제외 요청과 현재 청구 상태를 다시 확인해 주세요.');
  x.cancelled={reason,by:'청구 담당자 (시안)',at:new Date().toLocaleString('ko-KR'),changeRequestId:inv.changeRequest.id};inv.void=true;inv.accepted=false;x.lines=[];x.dirty=false;releaseEvidence(x);$('#manage-dialog').close();render();notify('고객의 전체 제외 요청을 확인하고 주문을 취소했어요. 기존 청구 이력은 남습니다.');
 }else if(form.id==='review-form'){
  const x=state.guests[state.reviewGuest];const actual=Math.round(Number(data.get('actual'))*100),reference=String(data.get('reference')).trim();if(!data.get('checked')||!reference||x.invoice.payment!=='pending_review')return;
  if(actual!==x.invoice.total)return notify('청구 금액과 수취 금액이 달라요. 추가 확인으로 처리해 주세요.');
  if(state.receiptRefs.includes(reference))return notify('이미 확인한 거래 식별자예요. 중복 수취인지 확인해 주세요.');
  state.receiptRefs.push(reference);x.invoice.payment='confirmed';x.history.push('실제 수취 내역 대조 후 입금 확정');render();notify('실제 수취 내역 확인을 기록했어요. 셀러 직접 수금으로 집계돼요.');
 }else if(form.id==='needs-info-form'){
  const x=state.guests[state.reviewGuest],reason=String(data.get('reason')).trim();if(!reason||x.invoice.payment!=='pending_review')return;x.reviewReason=reason;x.invoice.payment='needs_info';x.history.push(`추가 확인: ${reason}`);x.upload='empty';render();notify('추가 확인 사유가 고객 화면에 표시돼요.');
 }
});
render();
