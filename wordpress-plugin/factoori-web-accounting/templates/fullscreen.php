<?php
if (!defined('ABSPATH')) { exit; }
?><!doctype html>
<html <?php language_attributes(); ?>>
<head>
<meta charset="<?php bloginfo('charset'); ?>">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<?php wp_head(); ?>
</head>
<body <?php body_class('factoori-web-fullscreen'); ?>>
<?php wp_body_open(); ?>
<div class="factoori-web-frame">
<?php echo do_shortcode('[factoori_web_accounting]'); ?>
</div>
<?php wp_footer(); ?>
</body>
</html>