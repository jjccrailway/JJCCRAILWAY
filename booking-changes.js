(() => {
  'use strict';
  const URL='https://ocjyyfzuoiprwajwyize.supabase.co';
  const KEY='sb_publishable_XZu8suOKCWB9Zp7dYhzxgQ_Yaq5zxo8';
  const db=window.supabase.createClient(URL,KEY);
  const $=s=>document.querySelector(s);
  const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const peso=n=>'₱'+Number(n||0).toFixed(2);
  const fmt=d=>d?new Date(d).toLocaleString('en-PH',{dateStyle:'medium',timeStyle:'short'}):'—';
  const statusLabel=s=>String(s||'').replaceAll('_',' ');
  async function currentUser(){const {data,error}=await db.auth.getUser();if(error)throw error;if(!data.user){location.href='index.html';throw new Error('Please sign in first.');}return data.user;}
  function changeLines(changes){
    const out=[];
    if(changes.travel_date)out.push(`Outbound date: ${changes.travel_date}`);
    if(changes.return_travel_date)out.push(`Return date: ${changes.return_travel_date}`);
    if(changes.booking_class)out.push(`Class upgrade: ${changes.booking_class}`);
    (changes.passengers||[]).forEach(p=>out.push(`Additional passenger: ${p.full_name}`));
    return out.join('\n')||'No changes listed';
  }
  async function initHistory(){
    const message=$('#changeHistoryMessage'),list=$('#changeHistoryList');
    try{
      const user=await currentUser();
      const {data,error}=await db.from('booking_change_requests').select('*').eq('user_id',user.id).order('created_at',{ascending:false});
      if(error)throw error;
      if(!data?.length){message.textContent='You have no booking modification requests yet.';list.innerHTML='';return;}
      message.textContent='Your modification requests are shown below.';
      list.innerHTML=data.map(r=>`<article class="bc-request"><div class="bc-row"><strong>Request #${r.request_id} · ${esc(r.booking_reference)}</strong><span class="bc-status ${esc(r.status)}">${esc(statusLabel(r.status))}</span></div><p>${esc(changeLines(r.requested_changes)).replaceAll('\n','<br>')}</p><div class="bc-row"><span>Amount: <b>${peso(r.total_amount_due ?? r.amount_due)}</b></span><small>Created: ${fmt(r.created_at)}</small></div>${['pending_payment','rejected'].includes(r.status)?`<p>Payment deadline: <b>${fmt(r.payment_deadline_at)}</b></p><a class="btn-primary" href="booking-change-payment.html?id=${r.request_id}">Continue Payment</a>`:''}${r.admin_note?`<p class="notice notice-warn">${esc(r.admin_note)}</p>`:''}</article>`).join('');
    }catch(e){message.textContent=e.message||'Unable to load booking changes.';message.className='notice notice-err';}
  }
  async function initPayment(){
    const id=new URLSearchParams(location.search).get('id');
    const message=$('#mcpMessage'),panel=$('#mcpPayPanel'),submit=$('#mcpSubmit'),cancel=$('#mcpCancel'),file=$('#mcpReceipt');
    const preview=$('#mcpReceiptPreview'),previewName=$('#mcpReceiptFileName'),previewImage=$('#mcpReceiptImagePreview');
    const pdfLabel=$('#mcpReceiptPdfLabel'),dropArea=$('#mcpDropArea');
    const instructions=$('#mcpInstructions'),countdown=$('#mcpCountdown');
    const methodButton=$('#mcpConfirmMethod'),coinsInput=$('#mcpJcoinsAmount');
    let previewUrl=null,timer=null,deadlineMs=0,walletBalance=0,totalDue=0,currentRequest=null,selectedFile=null;
    const setMessage=(text,type='info')=>{message.textContent=text;message.className=`notice notice-${type}`;};
    const money=n=>'₱'+Number(n||0).toFixed(2);
    const selectedMethod=()=>document.querySelector('input[name="mcpPaymentMethod"]:checked')?.value||'cash';
    const maxCoins=()=>Math.min(walletBalance,totalDue);
    const selection=()=>{
      const method=selectedMethod();
      let coins=method==='cash'?0:Number(coinsInput?.value||0);
      if(method==='jcoins')coins=totalDue;
      coins=Math.round(coins*100)/100;
      return {method,coins,cash:Math.max(0,Math.round((totalDue-coins)*100)/100)};
    };
    const updateBreakdown=()=>{
      const s=selection();
      if($('#mcpBreakdownTotal'))$('#mcpBreakdownTotal').textContent=money(totalDue);
      if($('#mcpBreakdownCoins'))$('#mcpBreakdownCoins').textContent=money(s.coins);
      if($('#mcpBreakdownCash'))$('#mcpBreakdownCash').textContent=money(s.cash);
      if($('#mcpJcoinsWrap'))$('#mcpJcoinsWrap').hidden=s.method==='cash';
      if($('#mcpMethodNote'))$('#mcpMethodNote').textContent=s.cash>0
        ? `You will use ${money(s.coins)} JCoins and pay the remaining ${money(s.cash)} by cash. A receipt is required for the cash portion.`
        : 'The full amount will be paid using JCoins. No bank receipt is required; the modification will still wait for Admin approval.';
      return s;
    };
    const clearPreview=()=>{
      selectedFile=null;
      if(previewUrl){URL.revokeObjectURL(previewUrl);previewUrl=null;}
      if(file)file.value='';
      if(previewImage){previewImage.removeAttribute('src');previewImage.hidden=true;}
      if(pdfLabel)pdfLabel.hidden=true;
      preview?.classList.remove('show');
    };
    const setFile=f=>{
      if(!f)return;
      selectedFile=f;
      if(file){
        try{const transfer=new DataTransfer();transfer.items.add(f);file.files=transfer.files;}catch(_){}
      }
      previewName.textContent=f.name;
      if(previewUrl){URL.revokeObjectURL(previewUrl);previewUrl=null;}
      if(f.type.startsWith('image/')){
        previewUrl=URL.createObjectURL(f);
        previewImage.src=previewUrl;previewImage.hidden=false;
        if(pdfLabel)pdfLabel.hidden=true;
      }else{
        previewImage.removeAttribute('src');previewImage.hidden=true;
        if(pdfLabel)pdfLabel.hidden=false;
      }
      preview?.classList.add('show');
    };
    if(!id){setMessage('Missing modification request ID.','err');return;}
    try{
      const user=await currentUser();
      const [{data:r,error},{data:wallet,error:walletError}]=await Promise.all([
        db.from('booking_change_requests').select('*').eq('request_id',id).eq('user_id',user.id).maybeSingle(),
        db.from('jcoins_wallets').select('balance').eq('user_id',user.id).maybeSingle()
      ]);
      if(error)throw error;if(walletError)throw walletError;
      if(!r)throw new Error('Modification request not found.');
      currentRequest=r;walletBalance=Number(wallet?.balance||0);totalDue=Number(r.total_amount_due??r.amount_due??0);
      $('#mcpRef').textContent=r.booking_reference;
      $('#mcpAmount').textContent=money(totalDue);
      if($('#mcpExactAmount'))$('#mcpExactAmount').textContent=money(r.cash_amount??r.amount_due);
      $('#mcpWalletBalance').textContent=`${walletBalance.toLocaleString('en-PH',{minimumFractionDigits:2,maximumFractionDigits:2})} JCoins`;
      $('#mcpChanges').textContent=changeLines(r.requested_changes);
      $('#mcpStatus').textContent=statusLabel(r.status);
      document.querySelectorAll('[data-copy]').forEach(button=>{
        button.addEventListener('click',async()=>{
          try{await navigator.clipboard.writeText(button.dataset.copy);const old=button.textContent;button.textContent='Copied!';setTimeout(()=>button.textContent=old,1400);}
          catch(e){setMessage('Unable to copy. Please copy the details manually.','err');}
        });
      });
      if(r.status==='pending_review'){
        panel.hidden=true;if(countdown)countdown.hidden=true;
        $('#mcpDeadline').textContent='Paused – awaiting Admin approval';
        setMessage(r.payment_method==='jcoins'
          ? 'Your JCoins payment has been recorded. Your modification is waiting for Admin approval.'
          : 'Your receipt is already submitted and is awaiting Admin review. No countdown applies while you wait.','warn');
        return;
      }
      if(!['pending_payment','rejected'].includes(r.status)){
        panel.hidden=true;setMessage(`This request is ${statusLabel(r.status)} and cannot accept payment.`,'info');return;
      }
      deadlineMs=new Date(r.payment_deadline_at).getTime();
      $('#mcpDeadline').textContent=fmt(r.payment_deadline_at);
      if(!Number.isFinite(deadlineMs)||deadlineMs<=Date.now()){
        panel.hidden=true;if(countdown)countdown.hidden=true;
        $('#mcpDeadline').textContent=fmt(r.payment_deadline_at);
        setMessage('The 10-minute payment window has expired. Your original booking remains unchanged.','err');return;
      }
      panel.hidden=false;
      if(r.payment_method){
        document.querySelectorAll('input[name="mcpPaymentMethod"]').forEach(x=>{x.checked=x.value===r.payment_method;x.disabled=true;});
        if(coinsInput){coinsInput.value=Number(r.jcoins_amount||0).toFixed(2);coinsInput.disabled=true;}
        updateBreakdown();
        if(Number(r.cash_amount??r.amount_due)>0){
          instructions.hidden=false;
          $('#mcpExactAmount').textContent=money(r.cash_amount??r.amount_due);
          $('#mcpAmount').textContent=money(totalDue);
          methodButton.disabled=true;methodButton.textContent='Payment Method Confirmed';
        }
      }else{
        updateBreakdown();
      }
      countdown.hidden=false;
      const tick=()=>{
        const left=Math.max(0,deadlineMs-Date.now()),sec=Math.floor(left/1000);
        $('#mcpCountdownValue').textContent=`${String(Math.floor(sec/60)).padStart(2,'0')}:${String(sec%60).padStart(2,'0')}`;
        $('#mcpCountdownProgress').style.width=`${Math.max(0,Math.min(100,left/600000*100))}%`;
        if(left<=0){
          clearInterval(timer);timer=null;panel.hidden=true;countdown.hidden=true;
          setMessage('The 10-minute payment window has expired. Your original booking remains unchanged.','err');
        }
      };
      tick();timer=setInterval(tick,1000);
      document.querySelectorAll('input[name="mcpPaymentMethod"]').forEach(x=>x.addEventListener('change',updateBreakdown));
      coinsInput?.addEventListener('input',()=>{
        if(Number(coinsInput.value)>maxCoins())coinsInput.value=maxCoins().toFixed(2);
        if(Number(coinsInput.value)<0)coinsInput.value='0';
        updateBreakdown();
      });
      $('#mcpUseMax')?.addEventListener('click',()=>{coinsInput.value=Math.min(walletBalance,Math.max(0,totalDue-.01)).toFixed(2);updateBreakdown();});
      $('#mcpUseAll')?.addEventListener('click',()=>{document.querySelector('input[name="mcpPaymentMethod"][value="jcoins"]').checked=true;coinsInput.value=totalDue.toFixed(2);updateBreakdown();});
      methodButton.addEventListener('click',async()=>{
        const s=updateBreakdown();
        if(s.coins>walletBalance||s.coins<0||s.coins>totalDue)return setMessage('Please enter a valid JCoins amount within your available balance.','err');
        if(s.method==='jcoins'&&walletBalance<totalDue)return setMessage('Your JCoins balance is not enough to cover the full modification amount. Choose Cash or JCoins + Cash.','err');
        if(s.method==='mixed'&&(s.coins<=0||s.cash<=0))return setMessage('For JCoins + Cash, enter a JCoins amount greater than zero and less than the total amount.','err');
        if(Date.now()>=deadlineMs)return setMessage('The payment window has expired.','err');
        methodButton.disabled=true;methodButton.textContent='Confirming…';
        try{
          const {data:result,error:rpcError}=await db.rpc('set_booking_change_payment_method',{
            p_request_id:Number(id),p_payment_method:s.method,p_jcoins_amount:s.coins
          });
          if(rpcError)throw rpcError;
          if(!result?.success)throw new Error(result?.message||'Unable to confirm payment method.');
          currentRequest={...currentRequest,...result};
          if(s.cash===0){
            if(timer)clearInterval(timer);timer=null;
            countdown.hidden=true;instructions.hidden=true;
            panel.hidden=true;
            $('#mcpStatus').textContent='Pending review';
            $('#mcpDeadline').textContent='Paused – awaiting Admin approval';
            setMessage('Your full JCoins payment has been recorded successfully. Your modification is now waiting for Admin approval. No receipt or countdown is required.','success');
            return;
          }
          instructions.hidden=false;
          $('#mcpExactAmount').textContent=money(result.cash_amount??s.cash);
          $('#mcpStatus').textContent='Awaiting receipt';
          $('#mcpAmount').textContent=money(totalDue);
          methodButton.textContent='Payment Method Confirmed';
          setMessage(`Payment method saved. Use ${money(s.coins)} JCoins and upload a receipt for the remaining ${money(s.cash)}. Your countdown continues until the receipt is submitted.`,'info');
        }catch(e){
          setMessage(e.message||'Unable to confirm payment method.','err');
          methodButton.disabled=false;methodButton.textContent='Confirm Payment Method';
        }
      });
      file?.addEventListener('change',()=>setFile(file.files?.[0]));
      $('#mcpRemoveReceipt')?.addEventListener('click',()=>{clearPreview();setMessage('Receipt removed. You can choose another file.','info');});
      ['dragenter','dragover'].forEach(name=>dropArea?.addEventListener(name,e=>{e.preventDefault();e.stopPropagation();dropArea.classList.add('mcp-drop-active');}));
      ['dragleave','drop'].forEach(name=>dropArea?.addEventListener(name,e=>{e.preventDefault();e.stopPropagation();dropArea.classList.remove('mcp-drop-active');}));
      dropArea?.addEventListener('drop',e=>setFile(e.dataTransfer?.files?.[0]));
      submit.addEventListener('click',async()=>{
        const f=selectedFile||file?.files?.[0];
        if(!f)return setMessage('Please choose your receipt first.','err');
        if(!['image/jpeg','image/png','image/webp','application/pdf'].includes(f.type))return setMessage('Upload a JPG, PNG, WEBP, or PDF receipt.','err');
        if(f.size>5*1024*1024)return setMessage('Receipt must be 5 MB or smaller.','err');
        if(Date.now()>=deadlineMs)return setMessage('The payment window has expired.','err');
        submit.disabled=true;submit.textContent='Uploading receipt…';
        let path='';
        try{
          const safe=f.name.replace(/[^a-zA-Z0-9._-]/g,'_');
          path=`${user.id}/change-${r.request_id}/${Date.now()}-${safe}`;
          const {error:upErr}=await db.storage.from('payment-receipts').upload(path,f,{upsert:false,contentType:f.type});
          if(upErr)throw upErr;
          const {data:res,error:rpcErr}=await db.rpc('submit_booking_change_receipt',{p_request_id:Number(id),p_receipt_path:path});
          if(rpcErr)throw rpcErr;
          if(timer)clearInterval(timer);timer=null;
          countdown.hidden=true;instructions.hidden=true;panel.hidden=true;
          $('#mcpDeadline').textContent='Paused – receipt submitted';
          $('#mcpStatus').textContent='Awaiting review';
          setMessage('Receipt submitted successfully. Your modification is now awaiting Admin approval. The countdown has stopped and your original booking remains unchanged until approval.','success');
        }catch(e){
          if(path)await db.storage.from('payment-receipts').remove([path]);
          setMessage(e.message||'Unable to submit receipt.','err');
          submit.disabled=false;submit.textContent='Submit Receipt for Admin Review';
        }
      });
      cancel.addEventListener('click',async()=>{
        if(!confirm('Cancel this unpaid modification request? Your original booking will remain unchanged.'))return;
        cancel.disabled=true;
        const {error}=await db.rpc('cancel_booking_change_request',{p_request_id:Number(id)});
        if(error){setMessage(error.message,'err');cancel.disabled=false;return;}
        if(timer)clearInterval(timer);timer=null;panel.hidden=true;countdown.hidden=true;
        setMessage('Modification request cancelled. Your original booking is unchanged.','success');
        $('#mcpStatus').textContent='Cancelled';
      });
    }catch(e){setMessage(e.message||'Unable to load payment request.','err');}
  }
  document.addEventListener('DOMContentLoaded',()=>{const page=document.body.dataset.page;if(page==='booking-changes')initHistory();if(page==='booking-change-payment')initPayment();});
})();