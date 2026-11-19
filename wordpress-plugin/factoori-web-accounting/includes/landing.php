<?php
if (!defined('ABSPATH')) { exit; }

add_shortcode('factoori_web_landing', function () {
    $settings = factoori_web_settings();
    $login = home_url('/factoori-accounting/');
    $purchase = $settings['purchase_url'] ?? '';
    $download = $settings['mobile_download_url'] ?? '';
    ob_start(); ?>
    <main class="factoori-landing" dir="rtl" lang="fa">
      <style>
      .factoori-landing{--ink:#142238;--muted:#64748b;--primary:#087f78;--line:#e2e8f0;font-family:inherit;color:var(--ink);max-width:1120px;margin:auto;padding:28px 18px 60px;line-height:1.9}
      .factoori-landing *{box-sizing:border-box}.factoori-landing a{text-decoration:none}
      .fl-hero{border-radius:28px;padding:clamp(28px,6vw,64px);background:radial-gradient(circle at 8% 0%,#38bdf855,transparent 32%),linear-gradient(125deg,#10283d,#087f78 75%,#0f766e);color:white}
      .fl-kicker{font-size:13px;color:#c7f9ef;font-weight:700}.fl-hero h1{font-size:clamp(30px,5vw,52px);line-height:1.35;color:white;margin:12px 0}.fl-hero p{max-width:720px;color:#e0f2f1;font-size:16px}
      .fl-actions{display:flex;gap:12px;flex-wrap:wrap;margin-top:26px}.fl-btn{display:inline-flex;align-items:center;justify-content:center;padding:12px 22px;border-radius:13px;font-weight:800;background:white;color:#075e59}.fl-btn.alt{background:#ffffff18;border:1px solid #ffffff66;color:white}
      .fl-section{margin-top:48px}.fl-section h2{font-size:clamp(23px,3vw,32px);margin:0 0 10px}.fl-lead{color:var(--muted);margin:0 0 22px}
      .fl-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}.fl-card{background:#fff;border:1px solid var(--line);border-radius:18px;padding:20px;box-shadow:0 8px 24px #0f172a08}.fl-card h3{margin:0 0 7px;font-size:17px}.fl-card p{margin:0;color:var(--muted);font-size:14px}
      .fl-table-wrap{overflow-x:auto;border:1px solid var(--line);border-radius:18px;background:white}.fl-table{width:100%;border-collapse:collapse;min-width:570px}.fl-table th,.fl-table td{padding:14px 16px;text-align:right;border-bottom:1px solid var(--line)}.fl-table thead th{background:#f1f7f7;color:#153b47}.fl-table tr:last-child td{border-bottom:0}.fl-check{color:#087f78;font-weight:900}.fl-muted{color:#64748b;font-size:13px}
      .fl-steps{display:grid;gap:12px}.fl-step{display:flex;gap:14px;align-items:flex-start;border:1px solid var(--line);border-radius:16px;padding:17px;background:#fff}.fl-num{flex:none;width:34px;height:34px;border-radius:11px;background:#e5f5f2;color:#087f78;display:grid;place-items:center;font-weight:900}.fl-step h3{margin:0 0 4px;font-size:16px}.fl-step p{margin:0;color:var(--muted);font-size:14px}
      .fl-callout{background:#f0fdfa;border:1px solid #b7e4dc;border-radius:20px;padding:22px}.fl-callout strong{color:#075e59}.fl-faq{border-bottom:1px solid var(--line);padding:15px 0}.fl-faq summary{font-weight:800;cursor:pointer}.fl-faq p{color:var(--muted);margin:8px 0 0}.fl-end{background:#14283c;color:white;border-radius:22px;padding:28px;text-align:center;margin-top:48px}.fl-end h2{color:white}.fl-end p{color:#d4e3ed}
      @media(max-width:600px){.factoori-landing{padding:16px 12px 40px}.fl-hero{border-radius:20px}.fl-actions .fl-btn{width:100%}.fl-section{margin-top:36px}}
      </style>
      <section class="fl-hero"><span class="fl-kicker">مدیریت کسب‌وکار، ساده و یکپارچه</span><h1>فاکتوری؛ حسابداری همراه کسب‌وکار شما</h1><p>ابزار مدیریت فروش، صدور فاکتور، مشتریان، کالاها، دریافت‌ها و امور مالی. از اپلیکیشن اندروید یا نسخه وب استفاده کنید؛ با یک حساب کاربری و اطلاعات همگام.</p><div class="fl-actions"><a class="fl-btn" href="<?php echo esc_url($login); ?>">ورود به حسابداری آنلاین</a><a class="fl-btn alt" href="#fl-plans">مقایسه نسخه‌ها</a></div></section>
      <section class="fl-section"><h2>همه‌چیز برای مدیریت منظم‌تر</h2><p class="fl-lead">اطلاعات کسب‌وکار را در یک فضای مشترک مدیریت کنید.</p><div class="fl-grid">
        <article class="fl-card"><h3>🧾 صدور و مدیریت فاکتور</h3><p>ثبت فاکتور کالا و خدمات و دسترسی به سوابق فروش.</p></article>
        <article class="fl-card"><h3>👥 مدیریت اشخاص</h3><p>ثبت مشتریان و تأمین‌کنندگان و مشاهده گردش حساب.</p></article>
        <article class="fl-card"><h3>📦 کالا و موجودی</h3><p>مدیریت کالاها، قیمت‌ها و اطلاعات موجودی.</p></article>
        <article class="fl-card"><h3>💳 امور مالی</h3><p>ثبت دریافت‌ها، پرداخت‌ها، هزینه‌ها و پیگیری چک‌ها.</p></article>
      </div></section>
      <section class="fl-section" id="fl-plans"><h2>مقایسه نسخه رایگان و پریمیوم</h2><p class="fl-lead">نسخه رایگان برای شروع و آشنایی با امکانات فاکتوری است؛ نسخه پریمیوم برای دسترسی به امکانات حرفه‌ای و محدودیت‌های کمتر.</p>
        <div class="fl-table-wrap"><table class="fl-table"><thead><tr><th>امکانات</th><th>رایگان</th><th>پریمیوم</th></tr></thead><tbody>
          <tr><td>ساخت حساب و ورود</td><td class="fl-check">✓</td><td class="fl-check">✓</td></tr><tr><td>امکانات پایه حسابداری</td><td class="fl-check">✓</td><td class="fl-check">✓</td></tr>
          <tr><td>سقف مصرف و تعداد عملیات</td><td>دارای سهمیه رایگان</td><td>سقف بالاتر / امکانات بازشده</td></tr><tr><td>امکانات تخصصی قفل‌شده</td><td>طبق محدودیت پلن</td><td class="fl-check">فعال با لایسنس معتبر</td></tr>
          <tr><td>استفاده با حساب مشترک در اپ و وب</td><td>طبق دسترسی حساب</td><td>طبق دسترسی حساب</td></tr><tr><td>همگام‌سازی اطلاعات</td><td class="fl-check">✓</td><td class="fl-check">✓</td></tr>
        </tbody></table></div><p class="fl-muted">دسترسی هر قابلیت براساس وضعیت واقعی حساب و مجوزهای ثبت‌شده تعیین می‌شود؛ جزئیات سهمیه‌ها داخل برنامه نمایش داده می‌شود.</p>
      </section>
      <section class="fl-section"><h2>چطور شروع کنم؟</h2><p class="fl-lead">ثبت‌نام و استفاده از فاکتوری در چند مرحله ساده انجام می‌شود.</p><div class="fl-steps">
        <div class="fl-step"><span class="fl-num">۱</span><div><h3>ساخت حساب کاربری</h3><p>در اپ یا صفحه حسابداری وب، با ایمیل و رمز عبور ثبت‌نام کنید و در صورت نیاز ایمیل را تأیید کنید.</p></div></div>
        <div class="fl-step"><span class="fl-num">۲</span><div><h3>ورود و انتخاب کسب‌وکار</h3><p>با همان حساب وارد شوید و کسب‌وکار خود را ایجاد یا انتخاب کنید.</p></div></div>
        <div class="fl-step"><span class="fl-num">۳</span><div><h3>شروع با نسخه رایگان</h3><p>بدون خرید از امکانات پایه و سهمیه رایگان استفاده کنید؛ امکانات محدودشده در برنامه مشخص می‌شوند.</p></div></div>
        <div class="fl-step"><span class="fl-num">۴</span><div><h3>تهیه و فعال‌سازی لایسنس</h3><p>از مسیر رسمی خرید معرفی‌شده در برنامه یا سایت، لایسنس تهیه کنید. پس از تأیید نهایی پرداخت، دسترسی حرفه‌ای به حساب کاربری تخصیص داده می‌شود.</p></div></div>
      </div></section>
      <section class="fl-section"><div class="fl-callout"><h2>لایسنس چطور کار می‌کند؟</h2><p>لایسنس به <strong>حساب کاربری و ایمیل شما</strong> تعلق دارد، نه به یک گوشی خاص. پس از فعال شدن، با ورود به همان حساب در اپ یا وب، سطح دسترسی حرفه‌ای شناسایی می‌شود. برای اپ و وب به دو لایسنس جداگانه نیاز ندارید.</p><div class="fl-actions"><?php if ($purchase) : ?><a class="fl-btn" href="<?php echo esc_url($purchase); ?>">تهیه لایسنس پریمیوم</a><?php else : ?><a class="fl-btn" href="<?php echo esc_url($login); ?>">ورود و مشاهده مسیر خرید</a><?php endif; ?></div></div></section>
      <section class="fl-section"><h2>یک حساب؛ اپلیکیشن و نسخه وب</h2><p class="fl-lead">هرجا راحت‌ترید کار کنید؛ اطلاعات کسب‌وکار در فضای مشترک مدیریت می‌شود.</p><div class="fl-grid">
        <article class="fl-card"><h3>📱 اپلیکیشن اندروید</h3><p>برای ثبت و مدیریت امور روزانه در گوشی.</p><?php if ($download) : ?><p style="margin-top:12px"><a href="<?php echo esc_url($download); ?>">دریافت اپلیکیشن ←</a></p><?php endif; ?></article>
        <article class="fl-card"><h3>💻 نسخه وب</h3><p>برای کار با صفحه بزرگ‌تر در موبایل، تبلت یا رایانه؛ با همان ایمیل و رمز عبور.</p><p style="margin-top:12px"><a href="<?php echo esc_url($login); ?>">ورود به حسابداری وب ←</a></p></article>
      </div><div class="fl-callout" style="margin-top:16px"><strong>نکته:</strong> برای مشاهده اطلاعات یکسان، در هر دو نسخه با همان حساب و همان کسب‌وکار وارد شوید و همگام‌سازی را برقرار نگه دارید.</div></section>
      <section class="fl-section"><h2>پرسش‌های متداول</h2><details class="fl-faq"><summary>برای استفاده از نسخه وب باید حساب جداگانه بسازم؟</summary><p>خیر؛ با همان ایمیل و رمز عبور اپلیکیشن وارد نسخه وب شوید.</p></details><details class="fl-faq"><summary>اگر لایسنس را در اپ خریدم، در وب هم فعال است؟</summary><p>بله؛ وقتی لایسنس به حساب کاربری تخصیص داده و فعال شد، همان حساب در نسخه وب نیز سطح دسترسی را دریافت می‌کند.</p></details><details class="fl-faq"><summary>آیا می‌توانم فقط از نسخه رایگان استفاده کنم؟</summary><p>بله؛ می‌توانید با امکانات پایه و محدودیت‌های پلن رایگان شروع کنید و هر زمان خواستید ارتقا دهید.</p></details></section>
      <section class="fl-end"><h2>آماده شروع هستید؟</h2><p>با حساب فاکتوری خود وارد شوید و مدیریت کسب‌وکارتان را ادامه دهید.</p><a class="fl-btn" href="<?php echo esc_url($login); ?>">ورود به صفحه وب فاکتوری</a></section>
    </main>
    <?php return ob_get_clean();
});

function factoori_web_ensure_landing_page() {
    $page = get_page_by_path('web-factoori');
    if ($page instanceof WP_Post && has_shortcode($page->post_content, 'factoori_web_landing')) {
        update_option('factoori_web_intro_page_id', $page->ID);
        return;
    }
    if ($page instanceof WP_Post) { return; }
    $page_id = wp_insert_post(array(
        'post_type' => 'page', 'post_status' => 'publish',
        'post_title' => 'معرفی فاکتوری و ورود به نسخه وب',
        'post_name' => 'web-factoori', 'post_content' => '[factoori_web_landing]',
        'comment_status' => 'closed', 'ping_status' => 'closed',
    ), true);
    if (!is_wp_error($page_id) && $page_id) update_option('factoori_web_intro_page_id', (int) $page_id);
}
add_action('init', 'factoori_web_ensure_landing_page', 30);
