// Lightweight adaptations of ReactBits reveal, text sweep and pointer spotlight.
localize();
const guide=document.querySelector('.guide'),reduced=matchMedia('(prefers-reduced-motion:reduce)');
let visible=true,entered=false;
const animations=[];
function practice(){
  $('practice').textContent=tinybot.panel.viewState.available
    ?tr(guide.classList.contains('guide-step')?'就在这张卡片上试试':'右上角 +，添加你关心的事',guide.classList.contains('guide-step')?'Try this card.':'Use + to add what matters to you')
    :tr('在「看板入门」中，可以直接练习','Open Getting started to try these gestures');
}
function animate(element,frames,options){if(element)animations.push(element.animate(frames,options));}
function sync(){
  const active=tinybot.active&&visible&&!document.hidden;
  if(reduced.matches){animations.splice(0).forEach(animation=>animation.cancel());return;}
  if(active&&!entered){
    entered=true;
    guide.querySelectorAll('[data-reveal]').forEach((element,index)=>animate(element,
      [{opacity:0,transform:'translateY(10px)',filter:'blur(3px)'},{opacity:1,transform:'none',filter:'blur(0px)'}],
      {duration:440,delay:Math.min(index*55,220),easing:'cubic-bezier(.22,1,.36,1)',fill:'backwards'}));
    animate(guide.querySelector('.shine'),[{backgroundPosition:'150% 50%'},{backgroundPosition:'-50% 50%'}],{duration:1500,delay:200,easing:'ease-in-out'});
    const tile=guide.querySelector('.mini-tile');
    animate(tile,guide.classList.contains('resize')
      ?[{transform:'scale(1,1)',offset:0},{transform:'scale(1.38,1.26)',offset:.52},{transform:'scale(1.38,1.26)',offset:.7},{transform:'scale(1,1)',offset:1}]
      :[{transform:'translate(0,0)',offset:0},{transform:'translate(22%,18%)',offset:.52},{transform:'translate(22%,18%)',offset:.7},{transform:'translate(0,0)',offset:1}],
      {duration:3200,iterations:2,delay:400,easing:'cubic-bezier(.22,1,.36,1)'});
  }
  animations.forEach(animation=>{if(animation.playState!=='finished'){if(active)animation.play();else animation.pause();}});
}
function locate(event){const bounds=guide.getBoundingClientRect();guide.style.setProperty('--spot-x',(event.clientX-bounds.left)+'px');guide.style.setProperty('--spot-y',(event.clientY-bounds.top)+'px');guide.dataset.spot='true';}
guide.addEventListener('pointerdown',locate);guide.addEventListener('pointermove',locate);
guide.addEventListener('pointerleave',()=>{guide.dataset.spot='false';});
guide.addEventListener('pointerup',event=>{if(event.pointerType!=='mouse')guide.dataset.spot='false';});
guide.addEventListener('pointercancel',()=>{guide.dataset.spot='false';});
const observer=new IntersectionObserver(entries=>{visible=entries.some(entry=>entry.isIntersecting);sync();});observer.observe(guide);
tinybot.onState(sync);tinybot.panel.onUpdate(next=>{context=next;localize();practice();sync();});
document.addEventListener('visibilitychange',sync);reduced.addEventListener('change',sync);
practice();sync();
