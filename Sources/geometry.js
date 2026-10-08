'use strict';
class ReadingGeometry {
 constructor(paper,viewport,text,font,line,scroll,anchor,mirror){
  this.paper=paper;this.viewport=viewport;this.text=text;this.lineHeight=font*line;this.anchor=anchor;this.font=font;this.mirror=mirror;this.rects=new Map();this.rangeReads=0;this.rows=[];this.glyphs=[];
  const v=viewport.getBoundingClientRect();this.view={left:v.left,top:v.top,bottom:v.bottom,width:v.width,height:v.height};
  const closing={'（':'）','(':')','[':']','【':'】','{':'}','［':'］'},stack=[];let utf16=0;
  for(const char of text){if(closing[char])stack.push(closing[char]);if(stack.length){if(char===stack.at(-1))stack.pop()}else{const count=(char.normalize('NFKC').match(/[\p{L}\p{N}]/gu)||[]).length;for(let n=0;n<count;n++)this.glyphs.push({offset:utf16,size:char.length})}utf16+=char.length}
  const walk=document.createTreeWalker(paper,NodeFilter.SHOW_TEXT),nodes=[];let node,origin=0;while(node=walk.nextNode()){nodes.push({node,origin,font:parseFloat(getComputedStyle(node.parentElement).fontSize)});origin+=node.length}
  const rows=new Map(),segments=[];let gridOrigin=null;
  const rect=(node,start)=>{if(start>0&&/[\uDC00-\uDFFF]/.test(node.data[start]))start--;const size=node.data.codePointAt(start)>0xffff?2:1;const range=document.createRange();range.setStart(node,start);range.setEnd(node,Math.min(node.length,start+size));this.rangeReads++;return range.getBoundingClientRect()};
  for(const info of nodes){let start=0;while(start<info.node.length){const first=rect(info.node,start);let lo=start+1,hi=info.node.length;while(lo<hi){const mid=(lo+hi)>>1,r=rect(info.node,mid);if(r.top>first.top+2)hi=mid;else lo=mid+1}const end=lo;
    const adjusted=first.top-v.top+scroll-(font-info.font)*1.05;if(gridOrigin===null)gridOrigin=adjusted;const key=Math.round((adjusted-gridOrigin)/this.lineHeight);
    let row=rows.get(key);if(!row){row={key,y:adjusted,hasMain:info.font>=font-.5,segments:[],units:[],start:Infinity,end:0};rows.set(key,row)}else if(info.font>=font-.5&&!row.hasMain){row.y=adjusted;row.hasMain=true}
    const segment={node:info.node,start,end,origin:info.origin,row,first};row.segments.push(segment);segments.push(segment);start=end;
   }}
  this.allRows=[...rows.values()].sort((a,b)=>a.key-b.key);let segmentIndex=0;
  for(let u=0;u<this.glyphs.length;u++){const g=this.glyphs[u];while(segmentIndex<segments.length-1&&segments[segmentIndex].origin+segments[segmentIndex].end<=g.offset)segmentIndex++;const segment=segments[segmentIndex];if(!segment)continue;g.node=segment.node;g.index=g.offset-segment.origin;g.row=segment.row;segment.row.units.push(u);segment.row.start=Math.min(segment.row.start,u);segment.row.end=u+1}
  this.rows=this.allRows.filter(r=>r.units.length);this.totalUnits=this.glyphs.length;
  for(let i=0;i<this.rows.length;i++){const row=this.rows[i];row.count=row.end-row.start;row.nextY=this.rows[i+1]?.y??row.y+this.lineHeight}
 }
 unitForOffset(offset){let lo=0,hi=this.glyphs.length;while(lo<hi){const m=(lo+hi)>>1;if(this.glyphs[m].offset<offset)lo=m+1;else hi=m}return lo}
 offsetForUnit(unit){return unit>=this.totalUnits?this.text.length:this.glyphs[Math.max(0,Math.floor(unit))]?.offset||0}
 rowForUnit(unit){let lo=0,hi=this.rows.length;while(lo<hi){const m=(lo+hi)>>1;if(this.rows[m].end<=unit)lo=m+1;else hi=m}return this.rows[Math.min(lo,this.rows.length-1)]}
 yForUnit(unit){const row=this.rowForUnit(unit);if(!row)return 170;const fraction=Math.max(0,Math.min(1,(unit-row.start)/Math.max(1,row.count)));return row.y+(row.nextY-row.y)*fraction}
 slopeForUnit(unit){const row=this.rowForUnit(unit);return row?(row.nextY-row.y)/Math.max(1,row.count):0}
 unitForY(y){let lo=0,hi=this.rows.length;while(lo<hi){const m=(lo+hi)>>1;if(this.rows[m].nextY<=y)lo=m+1;else hi=m}const r=this.rows[Math.min(lo,this.rows.length-1)];return r?Math.max(0,Math.min(this.totalUnits,r.start+(y-r.y)/Math.max(1,r.nextY-r.y)*r.count)):0}
 cacheRow(unit,scroll){const row=this.rowForUnit(unit);if(!row||row.cached)return;row.cached=true;const v=this.view;
  for(const u of row.units){const g=this.glyphs[u];if(u>0&&g.offset===this.glyphs[u-1].offset&&this.rects.has(u-1)){this.rects.set(u,this.rects.get(u-1));continue}const range=document.createRange();range.setStart(g.node,g.index);range.setEnd(g.node,Math.min(g.node.length,g.index+g.size));const r=range.getBoundingClientRect();this.rangeReads++;this.rects.set(u,{left:r.left-v.left,top:r.top-v.top+scroll,width:r.width,height:r.height,bottom:r.bottom-v.top+scroll})}
 }
 glyphRect(unit){return this.rects.get(Math.min(this.totalUnits-1,Math.max(0,Math.floor(unit))))}
}
