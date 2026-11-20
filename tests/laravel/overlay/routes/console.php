<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

// CLI smoke test: MariaDB, Redis and the Redis cache store from php-cli.
Artisan::command('smoke:cli', function () {
    $ok = DB::connection()->getDriverName() === 'mariadb'
        && DB::selectOne('select 1 + 1 as v')->v == 2
        && in_array(Redis::connection()->ping(), [true, '+PONG', 'PONG'], true)
        && Cache::put('smoke-cli', 'ok', 60)
        && Cache::get('smoke-cli') === 'ok';

    $this->line($ok ? 'ok' : 'failed');

    return $ok ? 0 : 1;
});

Artisan::command('smoke:no-failed-jobs', function () {
    $count = DB::table('failed_jobs')->count();
    $this->line("failed jobs: {$count}");

    return $count === 0 ? 0 : 1;
});
