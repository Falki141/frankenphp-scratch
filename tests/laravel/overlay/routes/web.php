<?php

use App\Models\User;
use Illuminate\Cache\RedisStore;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Facades\Redis;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Str;

Route::get('/', function () {
    return view('welcome');
});

// Checks PHP runtime, MariaDB (query builder + Eloquent), Redis, cache and session.
Route::get('/smoke', function () {
    $email = 'smoke-'.Str::uuid().'@example.test';
    $user = User::create(['name' => 'Smoke', 'email' => $email, 'password' => 'secret']);
    $found = User::where('email', $email)->first();
    $user->delete();

    $token = (string) Str::uuid();
    Cache::put('smoke-cache', $token, 60);

    session()->put('counter', session('counter', 0) + 1);

    $ping = Redis::connection()->ping();

    return response()->json([
        'php' => PHP_VERSION,
        'sapi' => PHP_SAPI,
        'zts' => (bool) PHP_ZTS, // bool since PHP 8.5, int before
        'laravel' => app()->version(),
        'db_driver' => DB::connection()->getDriverName(),
        'db_server' => DB::selectOne('select version() as v')->v,
        'eloquent' => $found?->email === $email && User::where('email', $email)->doesntExist(),
        'password_hashed' => $found !== null && password_verify('secret', $found->password),
        'redis_client' => config('database.redis.client'),
        'redis_ping' => $ping === true || $ping === '+PONG' || $ping === 'PONG',
        'cache_redis' => Cache::getStore() instanceof RedisStore && Cache::get('smoke-cache') === $token,
        'session_driver' => config('session.driver'),
        'session_counter' => session('counter'),
    ]);
});

// Pushes a closure job onto the Redis queue; a CLI worker processes it.
Route::get('/smoke/queue', function () {
    $token = (string) Str::uuid();
    Cache::forget('smoke-job');
    dispatch(function () use ($token) {
        Cache::put('smoke-job', $token, 300);
    });

    return response()->json([
        'token' => $token,
        'queue_driver' => config('queue.default'),
        'queue_size' => Queue::size(),
    ]);
});

Route::get('/smoke/queue/result', function () {
    return response()->json(['token' => Cache::get('smoke-job')]);
});
