
async function showCloudMembers(){
 if(!cloudSchemaReady||!cloudActiveBusinessId)return toast('ابتدا کسب‌وکار مشترک را فعال کنید');
 try{
  const result=await window.FactooriCloud.manageBusinessMembers({action:'list',businessId:cloudActiveBusinessId});
  const members=result.members||[];window.factooriMemberCache=members;
  const labels={'contacts.read':'مشاهده اشخاص','contacts.write':'ویرایش اشخاص','catalog.read':'مشاهده کالاها','catalog.write':'ویرایش کالاها','sales.read':'مشاهده فاکتورها','sales.create':'صدور فاکتور','sales.post':'قطعی‌کردن فاکتور','payments.read':'مشاهده دریافت و پرداخت','payments.create':'ثبت دریافت و پرداخت','inventory.read':'مشاهده انبار','inventory.adjust':'اصلاح موجودی','inventory.transfer':'انتقال انبار','expenses.read':'مشاهده هزینه‌ها','expenses.create':'ثبت هزینه','reports.basic.read':'گزارش‌های عمومی','reports.profit.read':'گزارش سود و زیان','settings.manage':'مدیریت تنظیمات','members.manage':'مدیریت کارکنان'};
  const codes=Object.keys(labels);
  const rows=members.map(m=>'<div class="li"><div><b>'+esc(m.display_name||m.email)+'</b><br><small dir="ltr">'+esc(m.email)+'</small><br><small>'+esc(m.role_code)+' · '+esc(m.status)+'</small></div>'+(m.role_code!=='owner'?'<button class="b s" data-a="cloudMemberEditPermissions" data-user="'+esc(m.user_id)+'">دسترسی‌ها</button><button class="b s" data-a="cloudMemberStatus" data-user="'+esc(m.user_id)+'" data-status="'+(m.status==='active'?'suspended':'active')+'">'+(m.status==='active'?'تعلیق':'فعال‌سازی')+'</button>':'')+'</div>').join('');
  const perms=codes.map(c=>'<label style="display:flex;gap:8px;align-items:center;margin:6px 0"><input type="checkbox" data-member-perm="'+c+'" style="width:auto">'+labels[c]+'</label>').join('');
  $('ov').innerHTML='<div class="picker-shell"><div class="picker-top"><div class="r"><b style="flex:1">مدیریت کارکنان</b><button class="b s" data-a="cloudClose">بستن</button></div><p class="page-note">برای هر کارمند یک حساب مستقل بسازید. رمز تعیین‌شده، رمز اولیه ورود او خواهد بود.</p></div><div class="c"><h2>افزودن کارمند</h2><label>نام و نام خانوادگی</label><input id="memberDisplayName" placeholder="نام کارمند"><label>ایمیل ورود</label><input id="memberEmail" type="email" dir="ltr" placeholder="employee@example.com"><label>رمز اولیه (حداقل ۸ کاراکتر)</label><input id="memberPassword" type="password" dir="ltr"><label>نقش پایه</label><select id="memberRole"><option value="accountant">حسابدار</option><option value="warehouse">انباردار</option><option value="sales">فروشنده</option><option value="viewer">مشاهده‌گر</option><option value="admin">مدیر اجرایی</option></select><details><summary>مجوزهای اضافه برای این کارمند</summary><p class="page-note">مجوزهای انتخاب‌شده به نقش پایه اضافه می‌شوند. محدودیت‌های امنیتی حساس در سرور بررسی می‌شوند.</p>'+perms+'</details><button class="b w100" data-a="cloudMemberCreate">ساخت حساب کارمند</button></div><div class="c"><h2>کاربران ثبت‌شده</h2>'+(rows||'<p class="em">هنوز کارمندی ثبت نشده است.</p>')+'</div></div>';
  $('ov').className='on';
 }catch(e){toast('دریافت کارکنان ناموفق بود: '+(e.message||''))}
}


async function showCloudMemberPermissions(userId){
 const member=(window.factooriMemberCache||[]).find(x=>x.user_id===userId);if(!member)return;
 const labels={'contacts.read':'مشاهده اشخاص','contacts.write':'ویرایش اشخاص','catalog.read':'مشاهده کالاها','catalog.write':'ویرایش کالاها','sales.read':'مشاهده فاکتورها','sales.create':'صدور فاکتور','sales.post':'قطعی‌کردن فاکتور','payments.read':'مشاهده دریافت و پرداخت','payments.create':'ثبت دریافت و پرداخت','inventory.read':'مشاهده انبار','inventory.adjust':'اصلاح موجودی','inventory.transfer':'انتقال انبار','expenses.read':'مشاهده هزینه‌ها','expenses.create':'ثبت هزینه','reports.basic.read':'گزارش‌های عمومی','reports.profit.read':'گزارش سود و زیان','settings.manage':'مدیریت تنظیمات','members.manage':'مدیریت کارکنان'};
 const overrides=new Map((member.permission_overrides||[]).map(x=>[x.permission_code,x.allowed]));
 const controls=Object.keys(labels).map(code=>{const v=overrides.has(code)?(overrides.get(code)?'allow':'deny'):'inherit';return '<label>'+labels[code]+'</label><select data-edit-member-permission="'+code+'"><option value="inherit" '+(v==='inherit'?'selected':'')+'>مطابق نقش ('+esc(member.role_code)+')</option><option value="allow" '+(v==='allow'?'selected':'')+'>اجازه دسترسی</option><option value="deny" '+(v==='deny'?'selected':'')+'>عدم اجازه</option></select>'}).join('');
 $('ov').innerHTML='<div class="picker-shell"><div class="picker-top"><div class="r"><b style="flex:1">دسترسی‌های '+esc(member.display_name||member.email)+'</b><button class="b s" data-a="cloudManageMembers">بازگشت</button></div><p class="page-note">'+esc(member.email)+' · نقش پایه: '+esc(member.role_code)+'</p></div><div class="c">'+controls+'<button class="b w100" data-a="cloudMemberSavePermissions" data-user="'+esc(userId)+'">ذخیره دسترسی‌ها</button></div></div>';
 $('ov').className='on';
}

window.showCloudMembers=showCloudMembers;
window.showCloudMemberPermissions=showCloudMemberPermissions;
