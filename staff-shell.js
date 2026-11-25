(() => {
  'use strict';
  const URL='https://ocjyyfzuoiprwajwyize.supabase.co';
  const KEY='sb_publishable_XZu8suOKCWB9Zp7dYhzxgQ_Yaq5zxo8';
  if(!window.supabase || document.querySelector('.staff-top-actions')) return;
  const client=window.supabase.createClient(URL,KEY);
  const path=location.pathname.split('/').pop()||'admin.html';
  const items=[
    ['bookings.html','Bookings Management','▣'],
    ['fare-management.html','Train Fare Management','₱'],
    ['finance.html','Revenue & Transactions','▤'],
    ['payments.html','Payment Approvals','✓'],
    ['discount-review.html','Discount ID Verification','▧'],
    ['booking-change-review.html','Booking Change Review','↔'],
    ['delay-requests.html','Delay Compensation','◷']
  ];
  async function init(){
    const {data:userData,error:authError}=await client.auth.getUser();
    if(authError||!userData?.user)return;
    const {data:role,error:roleError}=await client.rpc('current_user_role');
    if(roleError||!['admin','super_admin'].includes(role))return;
    const dashboard=role==='super_admin'?'superadmin.html':'admin.html';
    const aside=document.querySelector('.sidebar,.staff-sidebar')||document.body.insertBefore(document.createElement('aside'),document.body.firstChild);
    aside.className='staff-sidebar';
    const dashboardLinks=role==='super_admin'
      ? `<a class="${path===dashboard&&!location.hash?'active':''}" href="superadmin.html"><span>▦</span>Dashboard Overview</a><a class="${location.hash==='#users'?'active':''}" href="superadmin.html#users"><span>♙</span>User Management</a><a class="${location.hash==='#admins'?'active':''}" href="superadmin.html#admins"><span>♜</span>Admin Management</a><a class="${location.hash==='#trains'?'active':''}" href="superadmin.html#trains"><span>🚆</span>Train Operations</a>`
      : `<a class="${path===dashboard?'active':''}" href="${dashboard}"><span>▦</span>Dashboard Overview</a>`;
    const privileged=role==='super_admin'?`<a href="superadmin.html#users"><span>♙</span>User Management</a><a href="superadmin.html#admins"><span>♜</span>Admin Management</a>`:'';
    aside.innerHTML=`<div class="staff-brand">🚆 JJCC <span>RAILWAYS</span></div><div class="staff-subtitle">${role==='super_admin'?'SUPER ADMIN PORTAL':'ADMIN PORTAL'}</div><div class="staff-section">WORKSPACE</div><nav>${dashboardLinks}${items.map(([href,label,icon])=>`<a class="${path===href?'active':''}" href="${href}"><span>${icon}</span>${label}</a>`).join('')}${privileged}</nav>`;
    document.body.classList.add('has-staff-sidebar');
    const actions=document.createElement('div');actions.className='staff-top-actions';
    const logout=document.createElement('button');logout.type='button';logout.className='staff-logout';logout.textContent='↪ Sign Out';
    logout.addEventListener('click',async()=>{logout.disabled=true;logout.textContent='Signing out…';const {error}=await client.auth.signOut();if(error){alert(error.message);logout.disabled=false;logout.textContent='↪ Sign Out';return}location.replace('index.html')});
    actions.appendChild(logout);

    const topbar=document.querySelector('.topbar');
    if(topbar){
      const right=topbar.children.length>1?topbar.lastElementChild:topbar;
      right.appendChild(actions);
      right.classList.add('staff-header-actions-host');
    }else{
      const header=document.querySelector('body>header');
      if(header){header.classList.add('staff-page-header');header.appendChild(actions)}
      else document.body.appendChild(actions);
    }
    const notificationScript=document.createElement('script');notificationScript.src='staff-notifications.js';notificationScript.defer=true;document.body.appendChild(notificationScript);
  }
  init().catch(err=>console.error('Staff navigation:',err));
})();