<?php
/**
 * Plugin Name: Factoori Web Accounting
 * Description: Full-screen Factoori accounting workspace backed by the same Supabase account and business data as the Android app.
 * Version: 0.1.3
 * Requires at least: 6.2
 * Requires PHP: 7.4
 * Author: Factoori
 * Text Domain: factoori-web-accounting
 */
if (!defined('ABSPATH')) { exit; }

define('FACTOORI_WEB_VERSION', '0.1.3');
define('FACTOORI_WEB_FILE', __FILE__);
define('FACTOORI_WEB_DIR', plugin_dir_path(__FILE__));

function factoori_web_defaults() {
    return array(
        'supabase_url' => 'https://rtlwztotaolbnjdtsjqy.supabase.co',
        'publishable_key' => 'sb_publishable_GhG0h_Mco3UomLqxnhynnw_blPQ3ii-',
        'purchase_url' => '',
    );
}
function factoori_web_settings() {
    return wp_parse_args(get_option('factoori_web_settings', array()), factoori_web_defaults());
}
function factoori_web_sanitize_settings($input) {
    $input = is_array($input) ? $input : array();
    return array(
        'supabase_url' => esc_url_raw(trim($input['supabase_url'] ?? '')),
        'publishable_key' => sanitize_text_field(trim($input['publishable_key'] ?? '')),
        'purchase_url' => esc_url_raw(trim($input['purchase_url'] ?? '')),
    );
}
add_action('admin_init', function () {
    register_setting('factoori_web_group', 'factoori_web_settings', array('sanitize_callback' => 'factoori_web_sanitize_settings'));
});
add_action('admin_menu', function () {
    add_options_page('Factoori Web Accounting', 'Factoori Web', 'manage_options', 'factoori-web-accounting', 'factoori_web_settings_page');
});
function factoori_web_settings_page() {
    if (!current_user_can('manage_options')) { return; }
    $s = factoori_web_settings();
    $page_id = absint(get_option('factoori_web_page_id', 0));
    $page_url = $page_id ? get_permalink($page_id) : '';
    ?>
    <div class="wrap">
      <h1>Factoori Web Accounting</h1>
      <p>تنظیمات اتصال نسخه وب به همان حساب و پایگاه داده اپلیکیشن فاکتوری.</p>
      <form method="post" action="options.php">
        <?php settings_fields('factoori_web_group'); ?>
        <table class="form-table" role="presentation">
          <tr><th><label for="factoori_supabase_url">Supabase URL</label></th><td><input id="factoori_supabase_url" class="regular-text" type="url" name="factoori_web_settings[supabase_url]" value="<?php echo esc_attr($s['supabase_url']); ?>" required></td></tr>
          <tr><th><label for="factoori_publishable_key">Publishable key</label></th><td><input id="factoori_publishable_key" class="large-text" type="text" name="factoori_web_settings[publishable_key]" value="<?php echo esc_attr($s['publishable_key']); ?>" required><p class="description">فقط کلید عمومی Publishable را وارد کنید؛ هرگز service_role یا secret key را اینجا قرار ندهید.</p></td></tr>
          <tr><th><label for="factoori_purchase_url">لینک خرید نسخه حرفه‌ای</label></th><td><input id="factoori_purchase_url" class="regular-text" type="url" name="factoori_web_settings[purchase_url]" value="<?php echo esc_attr($s['purchase_url']); ?>"></td></tr>
        </table>
        <?php submit_button('ذخیره تنظیمات'); ?>
      </form>
      <hr>
      <?php if ($page_url) : ?>
        <p><strong>صفحه حسابداری:</strong> <a href="<?php echo esc_url($page_url); ?>" target="_blank" rel="noopener">مشاهده فضای حسابداری آنلاین</a></p>
      <?php else : ?>
        <p>پس از فعال‌سازی افزونه، صفحه اختصاصی حسابداری به‌صورت خودکار ساخته می‌شود. در صورت حذف صفحه، یک برگه با کد <code>[factoori_web_accounting]</code> ایجاد کنید.</p>
      <?php endif; ?>
    </div>
    <?php
}
function factoori_web_has_shortcode() {
    if (!is_singular()) { return false; }
    $post = get_queried_object();
    return ($post instanceof WP_Post) && has_shortcode($post->post_content, 'factoori_web_accounting');
}
add_action('wp_enqueue_scripts', function () {
    if (!factoori_web_has_shortcode()) { return; }
    $s = factoori_web_settings();
    wp_enqueue_style('factoori-web-accounting', plugins_url('assets/app.css', __FILE__), array(), FACTOORI_WEB_VERSION);
    wp_enqueue_script('factoori-web-accounting', plugins_url('assets/app.js', __FILE__), array(), FACTOORI_WEB_VERSION, true);
    wp_localize_script('factoori-web-accounting', 'FACTOORI_WEB_CONFIG', array(
        'supabaseUrl' => untrailingslashit($s['supabase_url']),
        'publishableKey' => $s['publishable_key'],
        'purchaseUrl' => $s['purchase_url'],
        'version' => FACTOORI_WEB_VERSION,
    ));
}, 20);
add_shortcode('factoori_web_accounting', function () {
    return '<div id="factoori-web-root" dir="rtl" lang="fa"><div class="fw-loading">در حال آماده‌سازی فضای حسابداری فاکتوری…</div></div>';
});
add_filter('template_include', function ($template) {
    if (factoori_web_has_shortcode()) {
        $full = FACTOORI_WEB_DIR . 'templates/fullscreen.php';
        if (file_exists($full)) { return $full; }
    }
    return $template;
}, 99);

function factoori_web_activate() {
    $page = get_page_by_path('factoori-accounting');
    if ($page instanceof WP_Post && has_shortcode($page->post_content, 'factoori_web_accounting')) {
        update_option('factoori_web_page_id', $page->ID);
        return;
    }
    $page_id = wp_insert_post(array(
        'post_type' => 'page',
        'post_status' => 'publish',
        'post_title' => 'حسابداری آنلاین فاکتوری',
        'post_name' => 'factoori-accounting',
        'post_content' => '[factoori_web_accounting]',
        'comment_status' => 'closed',
        'ping_status' => 'closed',
    ), true);
    if (!is_wp_error($page_id) && $page_id) {
        update_option('factoori_web_page_id', (int) $page_id);
    }
}
register_activation_hook(__FILE__, 'factoori_web_activate');
