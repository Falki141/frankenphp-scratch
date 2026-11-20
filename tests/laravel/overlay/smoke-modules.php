<?php

// "frankenphp php-cli -m" is not available with PHP < 8.6, so list the
// loaded extensions from a script instead.
echo implode(PHP_EOL, get_loaded_extensions()), PHP_EOL;
