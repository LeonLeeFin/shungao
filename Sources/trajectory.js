'use strict';
// Numeric controller: no DOM queries and no ASR/model code in the frame loop.
class ReadingTrajectory {
 constructor(){this.reset(0,0)}
 reset(position,unit,now=0){Object.assign(this,{position,velocity:0,acceleration:0,confirmed:unit,rate:0,lastEvidence:now,lastRateTime:now,lastCapture:NaN,history:[],intervals:[],active:false,brake:null,relocation:null,predicted:unit,lastNow:now,anchorAge:0,pendingConfirmedSeek:false})}
 speaking(active,now){if(this.active===active)return;this.active=active;if(!active)this.startBrake(now);else{this.history=[];this.lastCapture=NaN;this.lastRateTime=now;this.lastEvidence=-Infinity;this.brake=null}}
 startBrake(now){if(this.brake||Math.abs(this.velocity)<.01){if(Math.abs(this.velocity)<.01)this.velocity=this.acceleration=0;return}const duration=Math.min(.11,12/Math.max(1,Math.abs(this.velocity)));this.brake={start:now,from:this.position,v:this.velocity,duration};this.relocation=null}
 observe(unit,now,meta,geometry){
  const delta=unit-this.confirmed,age=Number.isFinite(meta.capture_age)?Math.max(0,meta.capture_age):0;
  const capture=Number.isFinite(meta.capture_end)?meta.capture_end:now-age;
  if(meta.partial&&delta<0)return false;
  if(delta<0&&!meta.reread&&!meta.relocated)return false;
  const previousEvidence=this.lastEvidence;
  if(delta<0||meta.reread||meta.relocated){
   this.confirmed=unit;this.lastEvidence=now;this.captureAge=age;this.history=[];this.rate=0;this.lastCapture=NaN;
   if(this.active){const target=geometry.yForUnit(unit)-geometry.anchor;this.relocate(target,now,geometry.lineHeight)}else this.pendingConfirmedSeek=true;
   return true;
  }
  this.confirmed=unit;
  // Ordinary forward batches are confirmed reading, not a new seek animation.
  if(delta>0&&this.relocation&&!this.relocation.manual&&this.relocation.to>=this.relocation.from)this.relocation=null;
  if(!this.active)return true;
  if(Number.isFinite(previousEvidence)&&now-previousEvidence>.06&&now-previousEvidence<1.2){this.intervals.push(now-previousEvidence);this.intervals=this.intervals.slice(-12)}
  this.lastEvidence=now;this.captureAge=age;this.brake=null;
  // Collapse partial hypotheses from the same audio window to one rate point.
  const h=this.history;
  if(h.length&&Math.abs(capture-h.at(-1).t)<.035)h.at(-1).u=Math.max(h.at(-1).u,unit);
  else if(!h.length||capture>h.at(-1).t){h.push({t:capture,u:unit});while(h.length>10||h.length>2&&capture-h[0].t>2.1)h.shift()}
  const slopes=[];for(let i=0;i<h.length;i++)for(let j=i+1;j<h.length;j++){const dt=h[j].t-h[i].t,du=h[j].u-h[i].u;if(dt>=.12&&du>0&&du/dt<=22)slopes.push(du/dt)}
  if(slopes.length){
   const recent=h.filter(p=>capture-p.t<=.85),fast=[];
   for(let i=0;i<recent.length;i++)for(let j=i+1;j<recent.length;j++){const dt=recent[j].t-recent[i].t,du=recent[j].u-recent[i].u;if(dt>=.12&&du>0&&du/dt<=22)fast.push(du/dt)}
   const evidence=fast.length>=3?fast:slopes;evidence.sort((a,b)=>a-b);
   const measured=Math.max(.45,Math.min(18,evidence[evidence.length>>1])),dt=Math.max(.05,Math.min(.6,now-this.lastRateTime)),tau=measured>this.rate*1.25?.12:.30,alpha=1-Math.exp(-dt/tau);
   this.rate=this.rate?this.rate+(measured-this.rate)*alpha:measured;this.lastRateTime=now;
  }
  else if(!this.rate&&delta>0&&Number.isFinite(meta.audio_seconds)){this.rate=Math.max(.6,Math.min(14,delta/Math.max(.35,meta.audio_seconds)))}
  this.lastCapture=capture;return true;
 }
 relocate(target,now,lineHeight,manual=false){const distance=target-this.position,duration=Math.max(.28,Math.min(.58,.28+Math.abs(distance)/(lineHeight*22)));this.relocation={from:this.position,to:target,start:now,duration,v:this.velocity,a:this.acceleration,manual};this.brake=null}
 timeout(){if(!this.intervals.length)return .65;const a=[...this.intervals].sort((x,y)=>x-y);return Math.max(.5,Math.min(.95,a[a.length>>1]*2.6+.10))}
 step(now,dt,geometry){
  const oldVelocity=this.velocity;this.lastNow=now;this.anchorAge=Math.max(0,now-this.lastEvidence);
  const confirmedTarget=geometry.yForUnit(this.confirmed)-geometry.anchor;
  if(this.active&&this.pendingConfirmedSeek){this.pendingConfirmedSeek=false;this.relocate(confirmedTarget,now,geometry.lineHeight)}
  const freshAnchor=this.anchorAge+(this.captureAge||0)<=this.timeout();
  // Stale evidence stops prediction. While speaking, confirmed text can still
  // catch up; silence always brakes and retains the anchor for the next phrase.
  const behindConfirmed=confirmedTarget-this.position>.01;
  const valid=this.relocation?.manual===true||(this.active&&(freshAnchor||behindConfirmed||this.relocation!==null));
  if(!valid&&!this.brake&&Math.abs(this.velocity)>.01)this.startBrake(now);
  if(this.brake){const b=this.brake,u=Math.max(0,Math.min(1,(now-b.start)/b.duration)),d=b.duration;this.position=b.from+b.v*d*(u-u*u*u+.5*u*u*u*u);this.velocity=b.v*(1-3*u*u+2*u*u*u);this.acceleration=b.v/d*(-6*u+6*u*u);if(u>=1){this.velocity=this.acceleration=0;this.brake=null}return this.position}
  if(!valid){this.velocity=this.acceleration=0;return this.position}
  if(this.relocation){const r=this.relocation,u=Math.max(0,Math.min(1,(now-r.start)/r.duration)),d=r.duration,delta=r.to-r.from;
   const s=10*u**3-15*u**4+6*u**5,ds=30*u*u-60*u**3+30*u**4,dds=60*u-180*u*u+120*u**3;
   const h=u-6*u**3+8*u**4-3*u**5,dh=1-18*u*u+32*u**3-15*u**4,ddh=-36*u+96*u*u-60*u**3;
   this.position=r.from+delta*s+r.v*d*h;this.velocity=delta*ds/d+r.v*dh;this.acceleration=delta*dds/(d*d)+r.v*ddh/d;
   if(u>=1){this.relocation=null;this.velocity=this.acceleration=0}return this.position;
  }
  const row=geometry.rowForUnit(this.confirmed),lead=freshAnchor?Math.min(4,this.rate*.72,Math.max(1.5,(row?.count||8)*.5)):0;
  const elapsed=this.anchorAge+(this.captureAge||0),ahead=Math.min(lead,this.rate*elapsed);this.predicted=Math.min(geometry.totalUnits,this.confirmed+ahead);
  const desired=geometry.yForUnit(this.predicted)-geometry.anchor;
  let desiredVelocity=(freshAnchor&&ahead<lead-.001?this.rate*geometry.slopeForUnit(this.predicted):0);
  const confirmedY=geometry.yForUnit(this.confirmed)-geometry.anchor,lag=Math.max(0,confirmedY-this.position),catchup=Math.min(1,Math.max(0,lag/geometry.lineHeight-.18)/.65);
  const maxVelocity=geometry.lineHeight*(4+4*catchup),limitAcceleration=geometry.lineHeight*(14+30*catchup),limitJerk=geometry.lineHeight*(180+420*catchup);
  desiredVelocity=Math.max(0,Math.min(maxVelocity,desiredVelocity));
  // Feed-forward keeps moving between recognitions; a critically damped servo
  // corrects its phase. Neither position nor velocity is reset by an ASR tick.
  const substeps=Math.max(1,Math.ceil(dt/.008)),h=dt/substeps;
  for(let i=0;i<substeps;i++){
   const error=desired-this.position,omega=11+15*catchup;
   let a=omega*omega*error+2*omega*(desiredVelocity-this.velocity);
   a=Math.max(-limitAcceleration,Math.min(limitAcceleration,a));
   this.acceleration+=Math.max(-limitJerk*h,Math.min(limitJerk*h,a-this.acceleration));
   this.velocity=Math.max(0,Math.min(maxVelocity,this.velocity+this.acceleration*h));
   const before=this.position;this.position+=this.velocity*h;
   // Prediction has a hard spatial bound, including the controller itself.
   const maximum=geometry.yForUnit(Math.min(geometry.totalUnits,this.confirmed+lead))-geometry.anchor;
   if(this.position>maximum){this.position=Math.max(before,maximum);this.velocity=freshAnchor?Math.max(0,(this.position-before)/h):0;if(!freshAnchor)this.acceleration=0}
  }
  return this.position;
 }
}
