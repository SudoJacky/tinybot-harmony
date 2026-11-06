import { PROVIDER_LOGOS } from './ProviderLogoCatalog';

// Wallet-style HTML authoring reference for v2 Life Panels. No network or credentials in the page.
export const BALANCE_PANEL_HTML: string = `<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
*{box-sizing:border-box}body{margin:0;font:14px system-ui,sans-serif;color:var(--tinybot-text,#171717);background:var(--tinybot-surface,#fff)}
.wallet{--ease:cubic-bezier(.22,1,.36,1);--muted:color-mix(in srgb,currentColor 55%,transparent);--wash:color-mix(in srgb,currentColor 5%,transparent);container-type:inline-size;position:relative;isolation:isolate;padding:22px 24px 20px;border:1px solid color-mix(in srgb,currentColor 10%,transparent);border-radius:32px;margin:4px;overflow-wrap:anywhere}
button,input{font:inherit;color:inherit}button{border:0;cursor:pointer;background:transparent;padding:0;touch-action:manipulation;transition:transform 140ms var(--ease),background 140ms ease;min-height:44px}button:active{transform:scale(.95)}button:disabled{opacity:.45;cursor:default}button:focus-visible,input:focus-visible{outline:2px solid var(--tinybot-accent,#7b6be8);outline-offset:3px}
svg{width:20px;height:20px;display:block;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round;flex-shrink:0}.icon{display:grid;place-items:center;flex-shrink:0}.icon-button{width:44px;height:44px;border-radius:12px;color:var(--muted)}
header{position:relative;display:flex;align-items:center;justify-content:space-between;gap:4px;z-index:3;min-width:0}.account-trigger{display:flex;align-items:center;gap:8px;min-width:0;max-width:calc(100% - 44px);padding:6px 8px;margin-left:-8px;border-radius:16px;text-align:left}.account-name{font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}.chevron{width:14px;height:14px;color:var(--muted)}
.avatar{width:28px;height:28px;flex-shrink:0;border-radius:50%;display:grid;place-items:center;background:#edf0fa;color:#536079}.avatar img,.avatar svg{width:18px;height:18px;display:block;object-fit:contain}
.account-panel{position:absolute;top:0;left:-8px;right:-8px;visibility:hidden;pointer-events:none;transition:visibility 0s linear 220ms;--sx:.6;--sy:.2}
.account-panel[data-open=true]{visibility:visible;pointer-events:auto;transition-delay:0s}.panel-surface{position:absolute;inset:0;border:1px solid color-mix(in srgb,currentColor 10%,transparent);border-radius:16px;background:var(--tinybot-surface,#fff);box-shadow:0 14px 28px #00000012;opacity:0;transform:scale(var(--sx),var(--sy));transform-origin:left top;transition:transform 260ms var(--ease),opacity 160ms ease}
.account-panel[data-open=true] .panel-surface{opacity:1;transform:scale(1)}.panel-content{position:relative;opacity:0;transform:translateY(-3px);transition:opacity 130ms ease,transform 180ms var(--ease)}.account-panel[data-open=true] .panel-content{opacity:1;transform:none;transition-delay:40ms}
.panel-head{display:flex;align-items:center;gap:8px;width:100%;min-width:0;padding:6px 8px;text-align:left}.panel-head .account-name{flex:1}.panel-head .chevron{transform:rotate(180deg)}
#account-list{margin:0;padding:0 6px 6px;border:0;min-width:0;max-height:var(--account-list-height,128px);overflow:auto;overscroll-behavior:contain}.account-option{position:relative;display:flex;align-items:center;gap:9px;padding:9px 8px;border-radius:12px;min-height:48px;cursor:pointer;opacity:0;transform:translateY(-5px);transition:opacity 160ms ease,transform 200ms var(--ease),background 140ms ease}.account-panel[data-open=true] .account-option{opacity:1;transform:none;transition-delay:var(--delay,0ms)}
.account-option:has(:checked){background:var(--wash)}.account-option:has(:focus-visible){outline:2px solid var(--tinybot-accent,#7b6be8);outline-offset:-2px}.account-option input{position:absolute;opacity:0;width:1px;height:1px}.option-copy{min-width:0;flex:1}.option-copy span{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.option-copy .name{font-size:13px;font-weight:550}.option-copy .meta{font-size:11px;color:var(--muted);margin-top:2px}.selected-mark{width:16px;visibility:hidden}.account-option:has(:checked) .selected-mark{visibility:visible}
.hero{text-align:center;padding:16px 0 0}.caption{display:flex;align-items:center;justify-content:center;gap:2px;color:var(--muted);font-size:12px;min-height:20px}#privacy{width:44px;height:44px;min-height:44px;margin:-12px -8px;border-radius:50%;color:var(--muted)}#privacy svg{width:14px;height:14px;margin:auto}
#amount{--glyphs:8;display:grid;position:relative;font-size:32px;font-size:clamp(16px,calc(150cqi / var(--glyphs)),36px);font-weight:650;letter-spacing:-1.1px;font-variant-numeric:tabular-nums;line-height:1.35;margin:3px 0 6px;min-height:1.35em}.amount-layer{grid-area:1/1;min-width:0;white-space:pre-wrap;overflow-wrap:anywhere}.amount-layer span{display:inline-block;white-space:pre}.amount-out{pointer-events:none}
#time{margin:8px 0 0;font-size:10px;color:var(--muted)}
.loading-layer{grid-area:1/1;display:grid;min-height:1.35em}.amount-loading{align-self:center;justify-self:center;width:120px;max-width:75%;height:.8em;border-radius:8px;background:color-mix(in srgb,currentColor 14%,transparent);animation:balance-loading 1.2s ease-in-out infinite}
@keyframes balance-loading{0%,100%{opacity:.4}50%{opacity:1}}
#notice,#status{font-size:12px;color:var(--muted);line-height:1.5;margin:10px 0 0}#status[data-failed=true]{font-weight:550;color:var(--tinybot-text,#171717)}
[hidden]{display:none!important}#notice:empty,#status:empty{display:none}.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
@media(hover:hover) and (pointer:fine){.account-trigger:hover,.icon-button:hover,.account-option:hover{background:var(--wash)}}
@container(max-width:220px){.hero{padding-top:16px}.account-trigger{gap:5px}.account-name{font-size:12px}.avatar{width:24px;height:24px}}
@media(max-width:240px){.wallet{padding:18px 16px 16px;border-radius:24px}}
.wallet[data-keyboard=true] *{transition:none!important;animation:none!important}.wallet[data-keyboard=true] button:active{transform:none}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}button:active{transform:none}}
</style></head><body>
<article class="wallet" aria-label="Provider balance">
<header id="wallet-header">
<button id="account" class="account-trigger" aria-haspopup="dialog" aria-expanded="false" aria-controls="account-panel"><span id="account-avatar" class="avatar" aria-hidden="true"></span><span id="account-name" class="account-name"></span><span class="icon chevron" data-icon="chevron"></span></button>
<button id="refresh" class="icon-button" aria-label="Refresh balance"><span class="icon" data-icon="refresh"></span></button>
<div id="account-panel" class="account-panel" role="dialog" aria-labelledby="picker-title" data-open="false" inert>
<div class="panel-surface" aria-hidden="true"></div><div class="panel-content">
<button id="account-close" class="panel-head"><span id="panel-avatar" class="avatar" aria-hidden="true"></span><span id="picker-title" class="account-name"></span><span class="icon chevron" data-icon="chevron"></span></button>
<fieldset id="account-list"><legend class="sr-only" id="account-list-label">Accounts</legend><div id="account-options"></div></fieldset>
</div></div></header>
<div class="hero"><div class="caption"><span id="label"></span><button id="privacy" aria-label="Show balance" aria-pressed="true"></button></div>
<output id="amount" aria-live="polite" aria-label="••••••"></output><p id="time"></p></div>
<p id="notice" hidden></p><p id="status" role="status"></p>
</article><script>

const $=id=>document.getElementById(id);
const wallet=document.querySelector('.wallet'),reduced=matchMedia('(prefers-reduced-motion:reduce)');
let keyboard=false,pickerOpen=false,optionKey='',lastAmount='';
const logos=${JSON.stringify(PROVIDER_LOGOS)};
const paths={provider:'<path d="M6 18a4 4 0 0 1-.7-7.9A6 6 0 0 1 17 8.5 4.8 4.8 0 0 1 18 18Z"/>',chevron:'<path d="m7 10 5 5 5-5"/>',refresh:'<path d="M19 8a8 8 0 1 0 1 7M19 3v5h-5"/>',eye:'<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',eyeOff:'<path d="m3 3 18 18M9 5.4a11 11 0 0 1 3-.4c7 0 10 7 10 7a18 18 0 0 1-3 4M6 6c-3 2-4 6-4 6s3 7 10 7a11 11 0 0 0 5-1M10 10a3 3 0 0 0 4 4"/>',check:'<path d="m5 12 4 4L19 6"/>'};
function icon(name){return '<svg aria-hidden="true" viewBox="0 0 24 24">'+paths[name]+'</svg>';}
document.querySelectorAll('[data-icon]').forEach(el=>{el.innerHTML=icon(el.dataset.icon);});
const motion=()=>!reduced.matches&&!keyboard;
const stop=el=>{el.getAnimations({subtree:true}).forEach(animation=>animation.cancel());};
function animate(el,frames,duration=200,delay=0){if(motion())el.animate(frames,{duration,delay,easing:'cubic-bezier(.22,1,.36,1)',fill:'backwards'});}
function avatar(el,account){const preset=account?.presetId==='openai-responses'?'openai':account?.presetId;el.replaceChildren();if(preset&&Object.hasOwn(logos,preset)){const image=document.createElement('img');image.src=logos[preset];image.alt='';el.append(image);}else{el.innerHTML=icon('provider');}}
function amountText(row){if(row.unlimited||row.total===undefined)return row.unlimited?tr('无限额','Unlimited'):tr('未返回额度','Not provided');const parts=row.total.split('.');const grouped=parts[0].replace(/\\B(?=(\\d{3})+(?!\\d))/g,',')+(parts.length>1?'.'+parts[1]:'');return grouped;}
function amountLayer(value){const layer=document.createElement('span');layer.className='amount-layer';layer.setAttribute('aria-hidden','true');for(const char of value){const span=document.createElement('span');span.textContent=char;layer.append(span);}return layer;}
function showLoading(){const el=$('amount');el.setAttribute('aria-label',tr('正在加载余额','Loading balance'));if(el.dataset.loading==='true')return;el.dataset.loading='true';lastAmount='';stop(el);const layer=document.createElement('span');layer.className='loading-layer';layer.setAttribute('aria-hidden','true');const skeleton=document.createElement('span');skeleton.className='amount-loading';layer.append(skeleton);el.replaceChildren(layer);animate(layer,[{opacity:0,transform:'scale(.96)'},{opacity:1,transform:'scale(1)'}],140);}
function showAmount(value,immediate){const el=$('amount'),loading=el.dataset.loading==='true'?el.querySelector('.loading-layer'):null;el.dataset.loading='false';if(value===lastAmount&&!loading){if(immediate){stop(el);el.querySelectorAll('.amount-out').forEach(layer=>layer.remove());}return;}const old=lastAmount;lastAmount=value;stop(el);el.replaceChildren();el.setAttribute('aria-label',value);el.style.setProperty('--glyphs',Math.max(8,value.length));const fresh=amountLayer(value);el.append(fresh);
 if(immediate||!motion()||(!old&&!loading))return;
 const outgoing=loading||amountLayer(old);outgoing.classList.add('amount-out');el.prepend(outgoing);
 if(!loading)[...outgoing.children].forEach((char,i)=>animate(char,[{opacity:1,transform:'translateY(0)'},{opacity:0,transform:'translateY(-55%)'}],140,Math.min(i*6,48)));
 const finish=outgoing.animate([{opacity:1},{opacity:0}],{duration:190,easing:'ease-out'});finish.onfinish=()=>outgoing.remove();
 [...fresh.children].forEach((char,i)=>animate(char,[{opacity:0,transform:'translateY(60%)'},{opacity:1,transform:'translateY(0)'}],190,Math.min(i*12,84)));
}
function renderAccounts(){const accounts=context.data.accounts||[],key=JSON.stringify([accounts,context.inputs.providerId,zh()]);if(key===optionKey)return;optionKey=key;const list=$('account-options');list.replaceChildren();
 accounts.forEach((account,index)=>{const label=document.createElement('label');label.className='account-option';label.style.setProperty('--delay',Math.min(index*25,100)+'ms');const radio=document.createElement('input');radio.type='radio';radio.name='wallet-account';radio.value=account.id;radio.checked=account.id===context.inputs.providerId;radio.onchange=()=>{if(radio.checked){closePicker(true);if(account.id!==context.inputs.providerId)refresh(account.id);}};const orb=document.createElement('span');orb.className='avatar';orb.setAttribute('aria-hidden','true');avatar(orb,account);const copy=document.createElement('span');copy.className='option-copy';const name=document.createElement('span');name.className='name';name.textContent=account.name;const meta=document.createElement('span');meta.className='meta';meta.textContent=radio.checked?tr('当前账户','Current account'):tr('模型服务','Provider');copy.append(name,meta);const mark=document.createElement('span');mark.className='selected-mark icon';mark.innerHTML=icon('check');label.append(radio,orb,copy,mark);list.append(label);});
}
function sizePicker(){const available=wallet.getBoundingClientRect().bottom-$('account-list').getBoundingClientRect().top-12;$('account-list').style.setProperty('--account-list-height',Math.min(174,available)+'px');}
new ResizeObserver(()=>{if(pickerOpen)sizePicker();}).observe(wallet);
function openPicker(){if(localBusy||context.status==='running'||!context.canRefresh)return;renderAccounts();sizePicker();const panel=$('account-panel'),origin=$('account').getBoundingClientRect(),box=panel.getBoundingClientRect();panel.style.setProperty('--sx',Math.min(1,origin.width/box.width));panel.style.setProperty('--sy',Math.min(1,origin.height/box.height));pickerOpen=true;panel.inert=false;panel.dataset.open='true';$('account').setAttribute('aria-expanded','true');($('account-list').querySelector('input:checked')||$('account-close')).focus({preventScroll:true});}
function closePicker(restore=false){if(!pickerOpen)return;pickerOpen=false;const panel=$('account-panel');panel.dataset.open='false';panel.inert=true;$('account').setAttribute('aria-expanded','false');if(restore)$('account').focus({preventScroll:true});}
$('account').onclick=()=>pickerOpen?closePicker(true):openPicker();$('account-close').onclick=()=>closePicker(true);
document.addEventListener('pointerdown',event=>{keyboard=false;wallet.dataset.keyboard='false';if(pickerOpen&&!$('wallet-header').contains(event.target))closePicker();});
document.addEventListener('keydown',event=>{keyboard=true;wallet.dataset.keyboard='true';settleMotion();if(event.key==='Escape'&&pickerOpen){event.preventDefault();closePicker(true);}else if(event.key==='ArrowDown'&&document.activeElement===$('account')){event.preventDefault();openPicker();}});
$('wallet-header').addEventListener('focusout',()=>{setTimeout(()=>{if(pickerOpen&&!$('wallet-header').contains(document.activeElement))closePicker();},0);});
function settleMotion(){stop(wallet);wallet.querySelectorAll('.amount-out').forEach(el=>el.remove());}
reduced.addEventListener('change',settleMotion);

let context=tinybot.panel.context,privateMode=true,queryError='',storageError='',localBusy=false,storageReady=false,saved,lastAccount='';
const zh=()=>context.locale.startsWith('zh');
const tr=(a,b)=>zh()?a:b;
const text=(id,value)=>{$(id).textContent=value;};
function currentData(){return context.data&&context.data.providerId===context.inputs.providerId?context.data:null;}
function rows(){return currentData()?.amounts||[];}
function chosen(){return rows().find(row=>row.kind==='account')||rows()[0];}
function render(){
 const data=currentData(),amounts=rows(),busy=localBusy||context.status==='running',account=context.inputs.providerId;
 const accounts=context.data.accounts||[],accountChanged=account!==lastAccount;
 lastAccount=account;
 const selected=accounts.find(item=>item.id===account);text('account-name',selected?.name||tr('选择账户','Select account'));text('picker-title',selected?.name||tr('选择账户','Select account'));avatar($('account-avatar'),selected);avatar($('panel-avatar'),selected);renderAccounts();
 $('account').disabled=busy||!context.canRefresh;
 if(busy)closePicker();
 text('account-list-label',tr('账户','Accounts'));$('account-close').setAttribute('aria-label',tr('收起账户列表','Close account picker'));
 $('account').setAttribute('aria-label',tr('切换模型服务','Switch provider'));
 const row=chosen();text('label',row?row.label:tr('余额与额度','Balance and quota'));
 $('amount').setAttribute('aria-busy',String(busy));
 if(busy)showLoading();else showAmount(privateMode?'••••••':row?amountText(row):'—',privateMode||!data||accountChanged);
 $('privacy').innerHTML=icon(privateMode?'eyeOff':'eye');
 $('privacy').disabled=!storageReady;$('privacy').setAttribute('aria-label',tr(privateMode?'显示余额':'隐藏余额',privateMode?'Show balance':'Hide balance'));$('privacy').setAttribute('aria-pressed',String(privateMode));
 text('time',data?.checkedAt?tr('查询于 ','Checked ')+new Date(data.checkedAt).toLocaleString(context.locale):tr('尚未查询','Not queried yet'));
 const notice=data?.notice||(data?.available===false?tr('账户余额不足，暂不可调用 API','Insufficient balance for API calls'):'');
 text('notice',privateMode?'':notice);$('notice').hidden=privateMode||!notice;
 const failed=context.status==='failed';$('status').dataset.failed=String(failed);
 text('status',storageError||queryError|| (busy?'':failed?(data?tr('刷新失败 · 以下为上次结果','Refresh failed · Previous result'):tr('查询失败，请重试','Query failed. Try again.')):data&&!amounts.length?tr('服务未返回余额明细','No balance details returned'):''));
 $('refresh').disabled=busy||!context.canRefresh;$('refresh').setAttribute('aria-label',tr('刷新余额','Refresh balance'));$('refresh').setAttribute('aria-busy',String(busy));
}
async function refresh(id){if(localBusy||context.status==='running'||!context.canRefresh)return;localBusy=true;queryError='';render();try{await tinybot.panel.refresh(id?{providerId:id}:undefined);}catch(error){queryError=error.message;}finally{localBusy=false;render();}}

$('refresh').onclick=()=>refresh();
$('privacy').onclick=async()=>{const before=privateMode;privateMode=!privateMode;storageReady=false;storageError='';render();try{saved=await tinybot.storage.save({balanceHidden:privateMode},saved.revision);}catch(error){privateMode=before;storageError=error.message;}finally{storageReady=true;render();}};
tinybot.panel.onUpdate(next=>{context=next;if(next.status==='ready')queryError='';render();});
render();
tinybot.storage.load().then(value=>{saved=value;privateMode=value.value?.balanceHidden===true;storageReady=true;render();}).catch(error=>{storageError=error.message;render();});
</script></body></html>`;
