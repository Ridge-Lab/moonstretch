import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { transform_wav, transform_pcm, encode_wav } from '../_build/js/release/build/bridge/bridge.js';

// Independent RIFF fixture writer and reader: no MoonWavKit helper generates
// expected containers or interprets the resulting PCM.
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const build=path.join(root,'_build');fs.mkdirSync(build,{recursive:true});
const work=fs.mkdtempSync(path.join(build,'wav-verification-'));
let checks=0;
function wave(bits,channels,values,float=false) {
  const width=bits/8,size=values.length*width;
  const b=Buffer.alloc(44+size+(size%2));
  b.write('RIFF',0);b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8);
  b.writeUInt32LE(16,16);b.writeUInt16LE(float?3:1,20);b.writeUInt16LE(channels,22);
  b.writeUInt32LE(8000,24);b.writeUInt32LE(8000*channels*width,28);
  b.writeUInt16LE(channels*width,32);b.writeUInt16LE(bits,34);
  b.write('data',36);b.writeUInt32LE(size,40);
  const decoded=[];
  for(let i=0;i<values.length;i++) {
    const p=44+i*width,v=values[i];
    if(float){b.writeFloatLE(v,p);decoded.push(b.readFloatLE(p));}
    else if(bits===8){b[p]=Math.round((v+1)*127.5);decoded.push((b[p]-128)/128);}
    else {const full=2**(bits-1);b.writeIntLE(Math.round(v*(full-1)),p,width);decoded.push(b.readIntLE(p,width)/full);}
  }
  return {bytes:b,decoded};
}
function read24(bytes,channels,frames) {
  const b=Buffer.from(bytes);assert.equal(b.toString('ascii',0,4),'RIFF');
  assert.equal(b.readUInt32LE(4),b.length-8,'RIFF length includes chunk padding');
  assert.equal(b.toString('ascii',8,12),'WAVE');assert.equal(b.readUInt16LE(20),1);
  assert.equal(b.readUInt16LE(22),channels);assert.equal(b.readUInt32LE(24),8000);
  assert.equal(b.readUInt16LE(34),24);assert.equal(b.readUInt32LE(40),frames*channels*3);
  assert.equal(b.length,44+frames*channels*3+(frames*channels*3%2));
  return Array.from({length:frames*channels},(_,i)=>b.readIntLE(44+i*3,3)/8388608);
}
for(const [bits,float] of [[8,false],[16,false],[24,false],[32,false],[32,true]]) {
  for(const channels of [1,2,8]) for(const frames of [0,1,101]) {
    const values=Array.from({length:frames*channels},(_,i)=>0.65*Math.sin(i*0.19));
    const input=wave(bits,channels,values,float);
    const output=read24(transform_wav(input.bytes,1,0,1),channels,frames);
    output.forEach((x,i)=>assert.ok(Math.abs(x-input.decoded[i])<3e-7,`${bits}bit, ${channels}ch sample ${i}`));
    checks++;
  }
}
// Unknown chunks with odd padding, including an empty data chunk, must not
// prevent the delegated format parser from discovering fmt/data.
for(const frames of [0,3]) {
  const source=wave(16,1,Array(frames).fill(0.25)).bytes;
  const junk=Buffer.from([74,85,78,75,1,0,0,0,17,0]);
  const input=Buffer.concat([source.subarray(0,12),junk,source.subarray(12)]);
  input.writeUInt32LE(input.length-8,4);read24(transform_wav(input,1,0,1),1,frames);checks++;
}
const malformed=[];
for(const name of ['riff-short','riff-long','truncated','missing-pad','block-align','byte-rate','partial-frame','duplicate-fmt','duplicate-data','trailing-header']) {
  let b=wave(24,1,[0.1]).bytes;
  if(name==='riff-short')b.writeUInt32LE(4,4);
  if(name==='riff-long')b.writeUInt32LE(100000,4);
  if(name==='truncated')b=b.subarray(0,46);
  if(name==='missing-pad'){b=b.subarray(0,47);b.writeUInt32LE(b.length-8,4);}
  if(name==='block-align')b.writeUInt16LE(2,32);
  if(name==='byte-rate')b.writeUInt32LE(8000,28);
  if(name==='partial-frame'){b.writeUInt32LE(2,40);b=b.subarray(0,46);b.writeUInt32LE(b.length-8,4);}
  if(name==='duplicate-fmt'){b=Buffer.concat([b.subarray(0,36),b.subarray(12,36),b.subarray(36)]);b.writeUInt32LE(b.length-8,4);}
  if(name==='duplicate-data'){b=Buffer.concat([b,b.subarray(36)]);b.writeUInt32LE(b.length-8,4);}
  if(name==='trailing-header'){b=Buffer.concat([b,Buffer.alloc(2)]);b.writeUInt32LE(b.length-8,4);}
  malformed.push([name,b]);
}
for(const value of [NaN,Infinity,-Infinity])malformed.push(['float-'+String(value),wave(32,1,[value],true).bytes]);
for(const [name,input] of malformed) {
  assert.throws(()=>transform_wav(input,1,0,1),e=>e instanceof Error&&e.message.length>8,name);checks++;
}
assert.throws(()=>transform_pcm([NaN],8000,1,1,0,1),/finite|amplitude|PCM/);checks++;
assert.throws(()=>encode_wav([0.1],7999,1),/sample_rate/);checks++;
// Exercise the real CLI and its no-overwrite contract, not only the API.
const infile=path.join(work,'语音 input.wav'),outfile=path.join(work,'processed.wav');
fs.writeFileSync(infile,wave(16,2,Array.from({length:2002},(_,i)=>0.2*Math.sin(i*0.1))).bytes);
const cli=(args)=>spawnSync(process.execPath,[path.join(root,'scripts/moonstretch.mjs'),...args],{encoding:'utf8'});
let result=cli([infile,outfile,'--tempo','0.5','--pitch','7']);
assert.equal(result.status,0,result.stderr);read24(fs.readFileSync(outfile),2,2002);checks++;
const original=fs.readFileSync(outfile);
result=cli([infile,outfile]);assert.notEqual(result.status,0);assert.ok(result.stderr.trim().length>8);assert.deepEqual(fs.readFileSync(outfile),original);checks++;
const bad=path.join(work,'bad.wav'),never=path.join(work,'must-not-exist.wav');fs.writeFileSync(bad,malformed[0][1]);
result=cli([bad,never]);assert.notEqual(result.status,0);assert.match(result.stderr,/RIFF/);assert.equal(fs.existsSync(never),false);assert.equal(result.stdout,'');checks++;
console.log(`Verified ${checks} WAV/host cases: five PCM encodings, empty/odd-padded files, malformed input, meaningful errors and CLI no-overwrite.`);
