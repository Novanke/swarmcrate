///|
#external
priv type StageHandle

///|
extern "js" fn StageHandle::error(self : Self) -> String =
  #| h => h.error || ''

///|
extern "js" fn StageHandle::info(self : Self) -> String =
  #| h => JSON.stringify(h.info)

///|
// A handle owns only objects it created. Stable identity excludes mutable write times.
extern "js" fn stage_begin(
  target : String,
  expected_bytes : Int32,
) -> StageHandle =
  #| (target, expectedBytes) => {
  #|   const fs=process.getBuiltinModule('node:fs'), path=process.getBuiltinModule('node:path'), os=process.getBuiltinModule('node:os');
  #|   const h={error:'',fd:undefined,owned:new Map(),fs,path};
  #|   h.safe = p => { let cursor=path.parse(p).root; for(const part of p.slice(cursor.length).split(path.sep).filter(Boolean)){cursor=path.join(cursor,part);if(fs.lstatSync(cursor).isSymbolicLink())throw Error('symbolic links are unsupported');} };
  #|   h.id = s => s.ino===0n || s.birthtimeNs<=0n ? 'unsupported' : `${process.platform==='win32'?'win':s.dev}:${s.ino}:${s.birthtimeNs}`;
  #|   h.close = () => {const fd=h.fd;h.fd=undefined;fs.closeSync(fd);};
  #|   h.dispose = () => {
  #|     if(h.fd!==undefined){try{h.close();}catch{}}
  #|     if(!h.stage)return;
  #|     try{
  #|       h.safe(h.stage);
  #|       if(h.id(fs.lstatSync(h.stage,{bigint:true}))!==h.directoryId || h.directoryId==='unsupported')return;
  #|       const names=fs.readdirSync(h.stage);
  #|       if(names.some(n=>!h.owned.has(path.join(h.stage,n))))return;
  #|       for(const name of names){const p=path.join(h.stage,name),s=fs.lstatSync(p,{bigint:true});if(!s.isFile()||h.id(s)!==h.owned.get(p)||h.id(s)==='unsupported')return;}
  #|       for(const name of names){h.safe(h.stage);if(h.id(fs.lstatSync(h.stage,{bigint:true}))!==h.directoryId)return;const p=path.join(h.stage,name);if(h.id(fs.lstatSync(p,{bigint:true}))!==h.owned.get(p))return;fs.unlinkSync(p);}
  #|       fs.rmdirSync(h.stage);
  #|       if(h.receipt && h.owned.has(h.receipt)){h.safe(h.receipt);const s=fs.lstatSync(h.receipt,{bigint:true});if(s.isFile()&&h.id(s)===h.owned.get(h.receipt))fs.unlinkSync(h.receipt);}
  #|     }catch{}
  #|   };
  #|   try{
  #|     target=path.resolve(target);const parent=path.dirname(target);h.safe(parent);
  #|     const operation=process.getBuiltinModule('node:crypto').randomUUID().replaceAll('-','');
  #|     h.stage=fs.mkdtempSync(path.join(parent,'.swarmcrate-'+operation+'-'));
  #|     h.directoryId=h.id(fs.lstatSync(h.stage,{bigint:true}));
  #|     h.data=path.join(h.stage,'data');h.fd=fs.openSync(h.data,'wx',0o644);
  #|     const dataId=h.id(fs.fstatSync(h.fd,{bigint:true}));h.owned.set(h.data,dataId);
  #|     if(h.directoryId==='unsupported'||dataId==='unsupported')throw Error('publication filesystem lacks stable object identities');
  #|     const temp=fs.realpathSync(os.tmpdir());h.safe(temp);
  #|     h.receipt=path.join(temp,'.swarmcrate-owner-'+operation+'.json');
  #|     h.info={schema:'swarmcrate.staging-owner.v1',operation_id:operation,stage_path:h.stage,target_path:target,directory_id:h.directoryId,data_id:dataId,pid:process.pid,host:os.hostname(),user:os.userInfo().username,expected_bytes:String(expectedBytes)};
  #|     return h;
  #|   }catch(e){h.error=String(e.message||e);h.dispose();return h;}
  #| }

///|
extern "js" fn stage_handle_io(
  h : StageHandle,
  op : String,
  bytes : Bytes,
) -> IoResult =
  #| (h,op,bytes) => {
  #|   const {fs,path}=h;
  #|   const write = fd => {let used=0;while(used<bytes.length){const n=fs.writeSync(fd,bytes,used,bytes.length-used);if(!n)throw Error('short staged write');used+=n;}fs.fsyncSync(fd);};
  #|   const newFile = p => {let fd;try{fd=fs.openSync(p,'wx',0o600);h.owned.set(p,h.id(fs.fstatSync(fd,{bigint:true})));write(fd);const owned=fd;fd=undefined;fs.closeSync(owned);}finally{if(fd!==undefined){const owned=fd;fd=undefined;try{fs.closeSync(owned);}catch{}}}};
  #|   try{
  #|     if(op==='owner'){newFile(path.join(h.stage,'owner.json'));newFile(h.receipt);}
  #|     else if(op==='data'){write(h.fd);h.close();}
  #|     else if(op==='link'){h.safe(h.stage);if(h.id(fs.lstatSync(h.stage,{bigint:true}))!==h.directoryId||h.id(fs.lstatSync(h.data,{bigint:true}))!==h.info.data_id)throw Error('publication stage changed');fs.linkSync(h.data,h.info.target_path);}
  #|     else if(op==='dispose'){h.dispose();}
  #|     else throw Error('unknown stage handle operation');
  #|     return {error:''};
  #|   }catch(e){return {error:String(e.message||e)};}
  #| }

///|
// Small OS primitives. Destructive calls compare the exact observed object token,
// check every ancestor, and never recurse. MoonBit decides eligibility and sequence.
extern "js" fn stage_os(
  op : String,
  input : String,
  argument : String,
) -> IoResult =
  #| (op,input,argument) => {
  #|   try{
  #|     const fs=process.getBuiltinModule('node:fs'),path=process.getBuiltinModule('node:path'),os=process.getBuiltinModule('node:os');
  #|     const safe = p => {let cursor=path.parse(p).root;for(const part of p.slice(cursor.length).split(path.sep).filter(Boolean)){cursor=path.join(cursor,part);if(fs.lstatSync(cursor).isSymbolicLink())throw Error('symbolic links are unsupported');}};
  #|     const id = s => s.ino===0n||s.birthtimeNs<=0n?'unsupported':`${process.platform==='win32'?'win':s.dev}:${s.ino}:${s.birthtimeNs}`;
  #|     const stamp = s => `${s.dev}:${s.ino}:${s.size}:${s.mtimeNs}:${s.ctimeNs}`;
  #|     let text='';
  #|     if(op==='context')text=JSON.stringify({host:os.hostname(),user:os.userInfo().username});
  #|     else if(op==='probe'){try{process.kill(Number(argument),0);text='alive';}catch(e){text=e.code==='ESRCH'?'dead':'unknown';}}
  #|     else if(op==='receipt'){if(!/^[a-f0-9]{32}$/.test(argument))throw Error('invalid operation ID');const temp=fs.realpathSync(os.tmpdir());safe(temp);text=path.join(temp,'.swarmcrate-owner-'+argument+'.json');}
  #|     else {
  #|       const p=path.resolve(input);
  #|       if(op==='name'){text=path.basename(p);}
  #|       else if(op==='parent'){text=path.dirname(p);}
  #|       else if(op==='claim'){
  #|         safe(path.dirname(p));let fd;
  #|         try{fd=fs.openSync(p,'wx',0o600);const opened=fs.fstatSync(fd,{bigint:true}),named=fs.lstatSync(p,{bigint:true});if(!named.isFile()||id(opened)!==id(named))throw Error('cleanup claim changed');text=stamp(named);const owned=fd;fd=undefined;fs.closeSync(owned);}
  #|         finally{if(fd!==undefined){const owned=fd;fd=undefined;try{fs.closeSync(owned);}catch{}}}
  #|       }else{
  #|         safe(p);const s=fs.lstatSync(p,{bigint:true});
  #|         if(op==='identity')text=id(s);
  #|         else if(op==='receipt-safe'){if(!s.isFile()||(process.platform!=='win32'&&(s.uid!==BigInt(process.getuid())||(s.mode&0o077n)!==0n)))throw Error('unsafe local ownership receipt');}
  #|         else if(op==='unlink'){if(!s.isFile()||stamp(s)!==argument)throw Error('cleanup file changed');fs.unlinkSync(p);}
  #|         else if(op==='rmdir'){if(!s.isDirectory()||id(s)!==argument||argument==='unsupported')throw Error('cleanup directory changed');fs.rmdirSync(p);}
  #|         else throw Error('unknown stage OS operation');
  #|       }
  #|     }
  #|     return {error:'',text};
  #|   }catch(e){return {error:String(e.message||e),code:'staging'};}
  #| }

///|
fn stage_call(
  op : String,
  path : String,
  argument~ : String = "",
) -> String raise @lib.CrateError {
  let result = stage_os(op, path, argument)
  if result.error() != "" {
    raise @lib.CrateError(result.code(), result.error())
  }
  result.text()
}
