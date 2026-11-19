<?php
/**
 * Plugin Name: Web Factoori
 * Description: Factoori unified account bridge and product introduction page. Uses Supabase Auth as the single credential authority for Android, web accounting and the WordPress profile.
 * Version: 1.0.3
 * Requires at least: 6.2
 * Requires PHP: 7.4
 * Author: Factoori
 * Text Domain: web-factoori
 */
if (!defined('ABSPATH')) { exit; }

define('FACTOORI_INTRO_VERSION', '1.0.3');
define('FACTOORI_INTRO_SUPABASE_URL', 'https://rtlwztotaolbnjdtsjqy.supabase.co');
define('FACTOORI_INTRO_PUBLISHABLE_KEY', 'sb_publishable_GhG0h_Mco3UomLqxnhynnw_blPQ3ii-');

function factoori_intro_account_url() { return home_url('/account/'); }
function factoori_intro_confirmation_url() { return home_url('/email-confirmation/'); }
function factoori_intro_web_url() { return home_url('/factoori-accounting/'); }
function factoori_intro_purchase_url() { return home_url('/buy/'); }

add_action('rest_api_init', function () {
    register_rest_route('factoori-auth/v1', '/session', array(
        'methods' => 'POST',
        'permission_callback' => '__return_true',
        'callback' => 'factoori_intro_bridge_session',
    ));
});

function factoori_intro_bridge_session(WP_REST_Request $request) {
    $token = trim((string) $request->get_header('authorization'));
    if (stripos($token, 'Bearer ') !== 0) {
        return new WP_Error('factoori_auth_missing_token', 'لطفاً ابتدا با حساب فاکتوری وارد شوید.', array('status' => 401));
    }
    $access_token = trim(substr($token, 7));
    if (!$access_token || strlen($access_token) > 8192) {
        return new WP_Error('factoori_auth_invalid_token', 'نشست ورود معتبر نیست.', array('status' => 401));
    }

    // Validate the Supabase JWT server-to-server. No service-role key or password is exposed to the browser.
    $response = wp_remote_get(FACTOORI_INTRO_SUPABASE_URL . '/auth/v1/user', array(
        'timeout' => 15,
        'headers' => array(
            'apikey' => FACTOORI_INTRO_PUBLISHABLE_KEY,
            'Authorization' => 'Bearer ' . $access_token,
            'Accept' => 'application/json',
        ),
    ));
    if (is_wp_error($response) || wp_remote_retrieve_response_code($response) !== 200) {
        return new WP_Error('factoori_auth_invalid_token', 'اعتبار ورود فاکتوری تأیید نشد؛ دوباره وارد شوید.', array('status' => 401));
    }
    $identity = json_decode(wp_remote_retrieve_body($response), true);
    $email = isset($identity['email']) ? sanitize_email($identity['email']) : '';
    $supabase_id = isset($identity['id']) ? sanitize_text_field($identity['id']) : '';
    if (!$email || !is_email($email) || !$supabase_id || empty($identity['email_confirmed_at'])) {
        return new WP_Error('factoori_auth_email_unconfirmed', 'برای ورود به پروفایل سایت، ابتدا ایمیل حساب فاکتوری را تأیید کنید.', array('status' => 403));
    }

    // If a visitor already has a legacy WordPress session, only link it when
    // the verified Supabase email matches that exact profile.
    if (is_user_logged_in()) {
        $current_user = wp_get_current_user();
        if (strtolower((string) $current_user->user_email) !== strtolower($email)) {
            return new WP_Error('factoori_profile_email_mismatch', 'برای اتصال پروفایل قبلی، با همان ایمیلی وارد شوید که در پروفایل سایت ثبت شده است.', array('status' => 409));
        }
        $user = $current_user;
    } else {
        $user = get_user_by('email', $email);
    }
    if (!$user) {
        $display = '';
        if (!empty($identity['user_metadata']['display_name'])) $display = sanitize_text_field($identity['user_metadata']['display_name']);
        if (!$display) $display = sanitize_user(current(explode('@', $email)), true);
        $username = sanitize_user(current(explode('@', $email)), true);
        if (!$username) $username = 'factoori_user';
        $base = $username; $suffix = 1;
        while (username_exists($username)) { $username = $base . $suffix++; }
        $user_id = wp_insert_user(array(
            'user_login' => $username,
            'user_email' => $email,
            'user_pass' => wp_generate_password(48, true, true),
            'display_name' => $display ?: $username,
            'role' => get_role('customer') ? 'customer' : 'subscriber',
        ));
        if (is_wp_error($user_id)) {
            return new WP_Error('factoori_profile_create_failed', 'ساخت پروفایل سایت انجام نشد؛ لطفاً دوباره تلاش کنید.', array('status' => 500));
        }
        $user = get_user_by('id', $user_id);
    }

    update_user_meta($user->ID, 'factoori_supabase_user_id', $supabase_id);
    update_user_meta($user->ID, 'factoori_auth_provider', 'supabase');
    wp_set_current_user($user->ID);
    wp_set_auth_cookie($user->ID, true, is_ssl());
    do_action('wp_login', $user->user_login, $user);

    return rest_ensure_response(array(
        'ok' => true,
        'profile_url' => factoori_intro_account_url(),
        'message' => 'ورود یکپارچه فاکتوری با موفقیت انجام شد.',
    ));
}

function factoori_intro_auth_shortcode() {
    $config = array(
        'url' => FACTOORI_INTRO_SUPABASE_URL,
        'key' => FACTOORI_INTRO_PUBLISHABLE_KEY,
        'bridge' => esc_url_raw(rest_url('factoori-auth/v1/session')),
        'profile' => esc_url_raw(factoori_intro_account_url()),
        'confirmation' => esc_url_raw(factoori_intro_confirmation_url()),
    );
    ob_start(); ?>
    <section class="fi-auth" dir="rtl" lang="fa">
      <div class="fi-auth-card">
        <div class="fi-brand">فاکتوری</div>
        <h2>یک حساب برای تمام فاکتوری</h2>
        <p>با همان ایمیل و رمز عبور در اپلیکیشن اندروید، نسخه وب و پروفایل سایت وارد شوید.</p>
        <div class="fi-tabs"><button type="button" data-fi-mode="login" class="active">ورود</button><button type="button" data-fi-mode="signup">ثبت‌نام</button></div>
        <form class="fi-form">
          <label data-fi-name-wrap hidden>نام و نام خانوادگی<input name="name" autocomplete="name"></label>
          <label>ایمیل<input name="email" type="email" required autocomplete="email" dir="ltr"></label>
          <label>رمز عبور<input name="password" type="password" required minlength="8" autocomplete="current-password" dir="ltr"></label>
          <button class="fi-submit" type="submit">ورود به حساب</button>
          <div class="fi-message" role="status" aria-live="polite"></div>
        </form>
        <small>رمز عبور فقط توسط سرویس امن احراز هویت فاکتوری بررسی می‌شود و در وردپرس ذخیره نمی‌شود.</small>
      </div>
    </section>
    <style>
      .factoori-intro a{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:11px 17px;margin:6px 4px;border-radius:12px;background:#0f766e;color:#fff!important;text-decoration:none!important;font-weight:800;box-shadow:0 5px 14px #0f766e22;transition:transform .18s,box-shadow .18s}.factoori-intro a:hover{transform:translateY(-2px);box-shadow:0 8px 18px #0f766e30}.factoori-intro section:first-child a{background:#fff;color:#0f766e!important}
      .fi-auth{max-width:620px;margin:28px auto;padding:14px;font-family:inherit}.fi-auth-card{background:#fff;border:1px solid #e2e8f0;border-radius:22px;padding:26px;box-shadow:0 12px 36px #0f172a12;color:#14212b}.fi-brand{font-size:22px;font-weight:900;color:#0f766e}.fi-auth-card h2{margin:12px 0 6px;font-size:23px}.fi-auth-card p,.fi-auth-card small{color:#64748b;line-height:2}.fi-tabs{display:flex;gap:8px;margin:20px 0}.fi-tabs button{flex:1;padding:11px;border:1px solid #cbd5e1;border-radius:12px;background:#f8fafc;color:#334155;font:inherit}.fi-tabs button.active,.fi-submit{background:#0f766e;color:#fff;border-color:#0f766e}.fi-form label{display:block;margin:12px 0;font-size:13px;font-weight:700}.fi-form input{display:block;width:100%;margin-top:6px;padding:12px;border:1px solid #cbd5e1;border-radius:11px;font:inherit;box-sizing:border-box}.fi-submit{width:100%;padding:13px;border:0;border-radius:12px;font:inherit;font-weight:800;cursor:pointer}.fi-message{margin-top:12px;line-height:1.9;font-size:13px}.fi-message.error{color:#b91c1c}.fi-message.success{color:#047857}
    </style>
    <script>
    (()=>{const root=document.currentScript.previousElementSibling.previousElementSibling; if(!root||root.dataset.ready)return;root.dataset.ready='1';const cfg=<?php echo wp_json_encode($config); ?>;let mode='login',signupBusy=false;const form=root.querySelector('.fi-form'),msg=root.querySelector('.fi-message'),submit=root.querySelector('.fi-submit'),nameWrap=root.querySelector('[data-fi-name-wrap]'),pass=root.querySelector('[name=password]');const show=(text,type='')=>{msg.textContent=text;msg.className='fi-message '+type};const setMode=m=>{mode=m;nameWrap.hidden=m!=='signup';pass.autocomplete=m==='signup'?'new-password':'current-password';root.querySelectorAll('[data-fi-mode]').forEach(b=>b.classList.toggle('active',b.dataset.fiMode===m));submit.textContent=m==='signup'?'ایجاد حساب واحد':'ورود به حساب';show('')};root.querySelectorAll('[data-fi-mode]').forEach(b=>b.addEventListener('click',()=>setMode(b.dataset.fiMode)));form.addEventListener('submit',async e=>{e.preventDefault();const email=form.elements.email.value.trim().toLowerCase(),password=form.elements.password.value,name=form.elements.name.value.trim();if(!email||!password||(mode==='signup'&&!name))return show('همه اطلاعات لازم را وارد کنید.','error');const guardKey='factoori_signup_guard_'+email;if(mode==='signup'){if(signupBusy)return;if(Date.now()<Number(localStorage.getItem(guardKey)||0))return show('درخواست ثبت‌نام همین ایمیل اخیراً ارسال شده است. صندوق ورودی را بررسی کنید و فعلاً دوباره ثبت‌نام نزنید.','error');signupBusy=true;localStorage.setItem(guardKey,String(Date.now()+120000));}submit.disabled=true;submit.textContent='لطفاً صبر کنید…';try{const endpoint=mode==='signup'?('/auth/v1/signup?redirect_to='+encodeURIComponent(cfg.confirmation)):'/auth/v1/token?grant_type=password';const body=mode==='signup'?{email,password,data:{display_name:name}}:{email,password};const res=await fetch(cfg.url+endpoint,{method:'POST',headers:{apikey:cfg.key,'Content-Type':'application/json'},body:JSON.stringify(body)});const data=await res.json().catch(()=>({}));if(!res.ok){const code=data.code||data.error_code||'';const raw=(data.msg||data.message||data.error_description||data.error||'').toString();if(mode==='signup'&&(/already registered|already exists|user_already_exists|email_exists/i.test(raw+' '+code))){localStorage.removeItem(guardKey);throw new Error('این ایمیل قبلاً در فاکتوری ثبت‌نام شده است؛ از بخش ورود استفاده کنید.')}if(mode==='signup'&&[502,503,504].includes(res.status))throw new Error('سرویس ایمیل فاکتوری پاسخ کامل نداده است. ممکن است پیام تأیید ارسال شده باشد؛ فعلاً دوباره ثبت‌نام نزنید. ایمیل‌های قبلی را ملاک قرار ندهید؛ پس از رفع اختلال، فقط یک ایمیل جدید معتبر صادر می‌شود.');localStorage.removeItem(guardKey);throw new Error(raw||'درخواست انجام نشد.')}if(mode==='signup'&&Array.isArray(data.user?.identities)&&data.user.identities.length===0)throw new Error('این ایمیل قبلاً در فاکتوری ثبت‌نام شده است؛ از بخش ورود استفاده کنید.');if(mode==='signup'&&!data.access_token){show('حساب مرکزی ساخته شد. ایمیل خود را تأیید کنید؛ سپس با همین ایمیل و رمز در اپ، نسخه وب و پروفایل سایت وارد شوید.','success');setMode('login');return}const token=data.access_token;if(!token)throw new Error('توکن ورود دریافت نشد.');const session={access_token:token,refresh_token:data.refresh_token||null,token_type:data.token_type||'bearer',expires_in:data.expires_in||3600,expires_at:data.expires_at||Math.floor(Date.now()/1000)+(data.expires_in||3600),user:data.user};try{localStorage.setItem('factoori_web_session_v1',JSON.stringify(session));sessionStorage.setItem('factoori_web_session_v1',JSON.stringify(session));}catch(_){}const bridge=await fetch(cfg.bridge,{method:'POST',credentials:'same-origin',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'}});const linked=await bridge.json().catch(()=>({}));if(!bridge.ok)throw new Error(linked.message||linked.code||'اتصال پروفایل سایت انجام نشد.');show('ورود موفق بود؛ در حال انتقال به پروفایل…','success');location.href=linked.profile_url||cfg.profile}catch(err){const raw=err&&err.message?err.message:'خطا در ارتباط با سرویس.';if(mode==='signup'&&/failed to fetch|network|timeout|timed out/i.test(raw))show('ارتباط با سرویس ثبت‌نام قطع شد و وضعیت ساخت حساب مشخص نیست. فعلاً دوباره ثبت‌نام نزنید؛ صندوق ایمیل را بررسی کنید. اگر ایمیل‌های متعدد رسیده، هیچ‌کدام را تا رفع اختلال معتبر فرض نکنید.','error');else show(raw,'error')}finally{signupBusy=false;submit.disabled=false;submit.textContent=mode==='signup'?'ایجاد حساب واحد':'ورود به حساب'}});setMode('login')})();
    </script>
    <?php return ob_get_clean();
}

add_shortcode('factoori_unified_account', 'factoori_intro_auth_shortcode');

// Dedicated Supabase email-confirmation landing page.
function factoori_intro_confirmation_shortcode() {
    $config = array(
        'url' => FACTOORI_INTRO_SUPABASE_URL,
        'key' => FACTOORI_INTRO_PUBLISHABLE_KEY,
        'bridge' => esc_url_raw(rest_url('factoori-auth/v1/session')),
        'profile' => esc_url_raw(factoori_intro_account_url()),
    );
    ob_start(); ?>
    <section class="fi-confirm" dir="rtl" lang="fa" style="max-width:620px;margin:40px auto;padding:20px;font-family:inherit">
      <div style="background:#fff;border:1px solid #e2e8f0;border-radius:22px;padding:32px 24px;text-align:center;box-shadow:0 12px 36px #0f172a12">
        <div style="font-size:25px;font-weight:900;color:#0f766e">فاکتوری</div>
        <div class="fi-confirm-status" style="margin:22px 0;color:#334155;line-height:2">در حال بررسی لینک تأیید ایمیل…</div>
        <a class="fi-confirm-link" href="<?php echo esc_url(factoori_intro_account_url()); ?>" style="display:inline-block;background:#0f766e;color:#fff;padding:12px 24px;border-radius:12px;text-decoration:none;font-weight:800">ورود به حساب فاکتوری</a>
      </div>
    </section>
    <script>
    (()=>{const root=document.currentScript.previousElementSibling;if(!root||root.dataset.ready)return;root.dataset.ready='1';const cfg=<?php echo wp_json_encode($config); ?>;const status=root.querySelector('.fi-confirm-status');const params=new URLSearchParams(location.hash.replace(/^#/,''));const access=params.get('access_token');const error=params.get('error_description')||params.get('error');const say=(s,color)=>{status.textContent=s;status.style.color=color||'#334155'};if(error){say('تأیید ایمیل انجام نشد: '+error,'#b91c1c');return}if(!access){say('اگر روی لینک تأیید ایمیل کلیک کرده‌اید، وضعیت حساب را از بخش ورود بررسی کنید. در صورت نیاز، دوباره وارد شوید.');return}const session={access_token:access,refresh_token:params.get('refresh_token')||null,token_type:params.get('token_type')||'bearer',expires_in:Number(params.get('expires_in')||3600),expires_at:Math.floor(Date.now()/1000)+Number(params.get('expires_in')||3600)};try{localStorage.setItem('factoori_web_session_v1',JSON.stringify(session));sessionStorage.setItem('factoori_web_session_v1',JSON.stringify(session))}catch(_){}history.replaceState(null,document.title,location.pathname+location.search);fetch(cfg.bridge,{method:'POST',credentials:'same-origin',headers:{Authorization:'Bearer '+access,'Content-Type':'application/json'}}).then(async r=>({ok:r.ok,data:await r.json().catch(()=>({}))})).then(result=>{if(result.ok){say('آدرس ایمیل شما با موفقیت تأیید شد و حساب فاکتوری فعال است. اکنون می‌توانید وارد پروفایل خود شوید.','#047857')}else{say('ایمیل شما تأیید شد و حساب فعال است. برای ورود به پروفایل، از دکمه زیر وارد شوید.','#047857')}}).catch(()=>say('ایمیل شما تأیید شد. برای ورود به حساب فاکتوری از دکمه زیر استفاده کنید.','#047857'))})();
    </script>
    <?php return ob_get_clean();
}
add_shortcode('factoori_email_confirmation', 'factoori_intro_confirmation_shortcode');

// Create the dedicated confirmation page automatically after the plugin update.
function factoori_intro_ensure_confirmation_page() {
    $page = get_page_by_path('email-confirmation');
    if (!$page) {
        wp_insert_post(array(
            'post_type' => 'page',
            'post_status' => 'publish',
            'post_title' => 'تأیید ایمیل فاکتوری',
            'post_name' => 'email-confirmation',
            'post_content' => '[factoori_email_confirmation]',
            'comment_status' => 'closed',
        ));
    } elseif (strpos($page->post_content, '[factoori_email_confirmation]') === false) {
        wp_update_post(array('ID' => $page->ID, 'post_content' => '[factoori_email_confirmation]'));
    }
}
add_action('init', 'factoori_intro_ensure_confirmation_page', 30);


// Prevent a second, unrelated WordPress-only registration path.
add_filter('registration_errors', function ($errors) {
    if (is_wp_error($errors)) $errors->add('factoori_unified_registration', 'برای ساخت حساب فاکتوری فقط از ثبت‌نام یکپارچه استفاده کنید. همین حساب در اپلیکیشن، نسخه وب و پروفایل سایت قابل استفاده است.');
    return $errors;
}, 99);

// Replace the visible content of the site's account page with the unified Supabase sign-in.
// Existing WordPress user records are preserved and linked by their verified email on first login.
add_filter('the_content', function ($content) {
    if (is_admin() || !is_page('account') || !in_the_loop() || !is_main_query()) return $content;
    if (is_user_logged_in()) {
        $current_user = wp_get_current_user();
        $linked_id = get_user_meta($current_user->ID, 'factoori_supabase_user_id', true);
        // Legacy WordPress-only accounts get a one-time secure linking screen.
        // Once linked, the original site profile content is restored.
        if ($linked_id) return $content;
        return '<div class="fi-auth-link-notice" dir="rtl"><p>برای اتصال پروفایل قبلی به حساب یکپارچه فاکتوری، با همان ایمیل پروفایل خود وارد شوید. پس از اتصال، این مرحله دیگر نمایش داده نمی‌شود.</p>' . do_shortcode('[factoori_unified_account]') . '</div>';
    }
    return do_shortcode('[factoori_unified_account]');
}, 99);

function factoori_intro_landing_shortcode() {
    $account = esc_url(factoori_intro_account_url());
    $web = esc_url(factoori_intro_web_url());
    $buy = esc_url(factoori_intro_purchase_url());
    ob_start(); ?>
    <style>.factoori-intro a{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:11px 17px;margin:6px 4px;border-radius:12px;background:#0f766e;color:#fff!important;text-decoration:none!important;font-weight:800;box-shadow:0 5px 14px #0f766e22;transition:transform .18s,box-shadow .18s}.factoori-intro a:hover{transform:translateY(-2px);box-shadow:0 8px 18px #0f766e30}.factoori-intro section:first-child a{background:#fff;color:#0f766e!important}</style>
    <div class="factoori-intro" dir="rtl" lang="fa">
      <section style="padding:44px 20px;text-align:center;border-radius:26px;background:linear-gradient(135deg,#0f766e,#263b63);color:#fff">
        <h1 style="font-size:clamp(28px,5vw,46px);margin:0 0 14px">فاکتوری؛ یک حساب، همه‌جا همراه شما</h1>
        <p style="font-size:17px;line-height:2;max-width:760px;margin:0 auto 22px">اپلیکیشن اندروید، حسابداری آنلاین و پروفایل سایت همگی به یک حساب کاربری مرکزی متصل هستند. فقط یک‌بار ثبت‌نام کنید و با همان ایمیل و رمز در همه بخش‌ها وارد شوید.</p>
        <a href="<?php echo $account; ?>" style="display:inline-block;background:#fff;color:#0f766e;padding:13px 24px;border-radius:12px;text-decoration:none;font-weight:800">ورود یا ساخت حساب واحد</a>
      </section>
      <section style="padding:28px 8px"><h2>ثبت‌نام فقط یک‌بار انجام می‌شود</h2><p style="line-height:2">فرقی ندارد از اپلیکیشن، نسخه وب یا پروفایل سایت شروع کنید؛ حساب شما بر پایه ایمیل در سرویس احراز هویت مرکزی فاکتوری ساخته می‌شود. با همان اطلاعات ورود به هر سه محیط دسترسی دارید. اگر ایمیل قبلاً ثبت شده باشد، باید وارد حساب قبلی شوید و ثبت‌نام دوباره انجام نمی‌شود.</p>
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px">
          <div style="padding:18px;border:1px solid #dbe3ea;border-radius:16px"><h3>اپلیکیشن اندروید</h3><p>ورود و ثبت‌نام با حساب مرکزی فاکتوری و دسترسی به اطلاعات مشترک.</p></div>
          <div style="padding:18px;border:1px solid #dbe3ea;border-radius:16px"><h3>نسخه وب حسابداری</h3><p>ورود با همان ایمیل و رمز؛ بدون ساخت حساب جداگانه.</p><a href="<?php echo $web; ?>">ورود به نسخه وب</a></div>
          <div style="padding:18px;border:1px solid #dbe3ea;border-radius:16px"><h3>پروفایل سایت</h3><p>پروفایل سایت به حساب مرکزی متصل می‌شود؛ خرید و اطلاعات حساب در همان پروفایل نمایش داده می‌شود.</p><a href="<?php echo $account; ?>">ورود به پروفایل / ثبت‌نام</a></div>
        </div>
      </section>
      <section style="padding:12px 8px"><h2>انتخاب نسخه مناسب</h2><div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:16px">
        <div style="border:1px solid #dbe3ea;border-radius:18px;padding:20px"><h3>نسخه رایگان</h3><p>برای شروع و آشنایی با امکانات فاکتوری.</p><ul><li>ساخت حساب مرکزی فقط یک‌بار</li><li>استفاده آزمایشی از نسخه وب و اپ با محدودیت‌های رایگان</li><li>اطلاعات حساب در محیط‌های متصل مشترک است</li></ul><a href="<?php echo $web; ?>">ورود و شروع رایگان نسخه وب</a></div>
        <div style="border:2px solid #0f766e;border-radius:18px;padding:20px"><h3>نسخه حرفه‌ای</h3><p>برای دسترسی به امکانات کامل و بدون محدودیت‌های نسخه رایگان.</p><ul><li>خرید و مدیریت مجوز از پروفایل سایت</li><li>اتصال مجوز به حساب و ایمیل کاربر</li><li>استفاده در اپ و نسخه وب با همان حساب</li></ul><a href="<?php echo $account; ?>">ورود به پروفایل و خرید نسخه حرفه‌ای</a> · <a href="<?php echo $buy; ?>">صفحه خرید</a></div>
      </div></section>
      <section style="padding:22px 8px;text-align:center"><h2>یک ثبت‌نام؛ سه مسیر ورود</h2><p>ثبت‌نام در سایت، اپلیکیشن یا نسخه وب حساب جداگانه ایجاد نمی‌کند. اگر قبلاً با ایمیل خود حساب ساخته‌اید، فقط وارد شوید.</p><a href="<?php echo $account; ?>" style="display:inline-block;background:#0f766e;color:#fff;padding:13px 24px;border-radius:12px;text-decoration:none;font-weight:800">ورود / ثبت‌نام حساب واحد</a></section>
    </div>
    <?php return ob_get_clean();
}
add_shortcode('factoori_intro_landing', 'factoori_intro_landing_shortcode');

function factoori_intro_activate() {
    $page = get_page_by_path('web-factoori');
    if (!$page) {
        $id = wp_insert_post(array(
            'post_type' => 'page', 'post_status' => 'publish',
            'post_title' => 'معرفی نسخه وب فاکتوری', 'post_name' => 'web-factoori',
            'post_content' => '[factoori_intro_landing]', 'comment_status' => 'closed',
        ), true);
        if (!is_wp_error($id) && $id) update_option('factoori_intro_page_id', (int) $id);
    } elseif (strpos($page->post_content, '[factoori_web_landing]') !== false || strpos($page->post_content, '[factoori_intro_landing]') !== false) {
        wp_update_post(array('ID' => $page->ID, 'post_content' => '[factoori_intro_landing]'));
        update_option('factoori_intro_page_id', (int) $page->ID);
    }
}
register_activation_hook(__FILE__, 'factoori_intro_activate');
