use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

our $HttpConfig = qq{
lua_package_path "$pwd/lib/?.lua;;";

init_by_lua_block {
    require("luacov.runner").init()
}
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

no_long_string();
run_tests();

__DATA__

=== TEST 1: basic connect
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local rc = require("resty.redis.connector").new({
            port = $TEST_NGINX_REDIS_PORT
        })

        local redis, err = assert(rc:connect(params),
            "connect should return positively")

        assert(redis:set("dog", "an animal"),
            "redis:set should return positively")

        redis:close()
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 2: try_hosts
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors off;
    content_by_lua_block {
        local rc = require("resty.redis.connector").new({
            connect_timeout = 100,
        })

        local hosts = {
            { host = "127.0.0.1", port = 1 },
            { host = "127.0.0.1", port = 2 },
            { host = "127.0.0.1", port = $TEST_NGINX_REDIS_PORT },
        }

        local redis, err, previous_errors = rc:try_hosts(hosts)
        assert(redis and not err,
            "try_hosts should return a connection and no error")

        assert(previous_errors[1] == "connection refused",
            "previous_errors[1] should be 'connection refused'")
        assert(previous_errors[2] == "connection refused",
            "previous_errors[2] should be 'connection refused'")

        assert(redis:set("dog", "an animal"),
            "redis connection should be working")

        redis:close()

        local hosts = {
            { host = "127.0.0.1", port = 1 },
            { host = "127.0.0.1", port = 2 },
        }

        local redis, err, previous_errors = rc:try_hosts(hosts)
        assert(not redis and err == "no hosts available",
            "no available hosts should return an error")

        assert(previous_errors[1] == "connection refused",
            "previous_errors[1] should be 'connection refused'")
        assert(previous_errors[2] == "connection refused",
            "previous_errors[2] should be 'connection refused'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 3: connect_to_host
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local rc = require("resty.redis.connector").new()

        local host = { host = "127.0.0.1", port = $TEST_NGINX_REDIS_PORT }

        local redis, err = rc:connect_to_host(host)
        assert(redis and not err,
            "connect_to_host should return positively")

        assert(redis:set("dog", "an animal"),
            "redis connection should be working")

        redis:close()
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 4: connect_to_host options ignore defaults
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local rc = require("resty.redis.connector").new({
            port = $TEST_NGINX_REDIS_PORT,
            db = 2,
        })

        local redis, err = assert(rc:connect_to_host({
            host = "127.0.0.1",
            db = 1,
            port = $TEST_NGINX_REDIS_PORT
        }), "connect_to_host should return positively")

        assert(redis:set("dog", "an animal") == "OK",
            "set should return 'OK'")

        redis:select(2)
        assert(redis:get("dog") == ngx.null,
            "dog should not exist in db 2")

        redis:select(1)
        assert(redis:get("dog") == "an animal",
            "dog should be 'an animal' in db 1")

        redis:close()
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 5: Test set_keepalive method
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local rc = require("resty.redis.connector").new({
            port = $TEST_NGINX_REDIS_PORT,
        })

        local redis = assert(rc:connect(),
            "rc:connect should return positively")
        local ok, err = rc:set_keepalive(redis)
        assert(not err, "set_keepalive error should be nil")

        local ok, err = redis:set("foo", "bar")
        assert(not ok, "ok should be nil")
        assert(string.find(err, "closed"), "error should contain 'closed'")

        local redis = assert(rc:connect(), "connect should return positively")
        assert(redis:subscribe("channel"), "subscribe should return positively")

        local ok, err = rc:set_keepalive(redis)
        assert(not ok, "ok should be nil")
        assert(string.find(err, "subscribed state"),
            "error should contain 'subscribed state'")

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 6: password
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local rc = require("resty.redis.connector").new({
            port = $TEST_NGINX_REDIS_PORT,
            password = "foo",
        })

        local redis, err = rc:connect()
        assert(not redis and string.find(err, "ERR Client sent AUTH, but no password is set"),
            "connect should fail with password error")

    }
}
--- request
GET /t
--- error_log
ERR Client sent AUTH, but no password is set


=== TEST 7: unix domain socket
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local redis,  err = require("resty.redis.connector").new({
            path = "unix://tmp/redis.sock",
        }):connect()

        assert(not redis and err == "no such file or directory",
            "bad domain socket should fail")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 8: parse_dsn
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local rc = require("resty.redis.connector")

        local user_params = {
            url = "redis://foo@127.0.0.1:$TEST_NGINX_REDIS_PORT/4"
        }

        local params, err = rc.parse_dsn(user_params)
        assert(params and not err,
            "url should parse without error: " .. tostring(err))

		assert(params.host == "127.0.0.1", "host should be localhost")
		assert(tonumber(params.port) == $TEST_NGINX_REDIS_PORT,
			"port should be $TEST_NGINX_REDIS_PORT")
		assert(tonumber(params.db) == 4, "db should be 4")
		assert(params.password == "foo", "password should be foo")


		local user_params = {
			url = "sentinel://foo@foomaster:s/2"
		}

		local params, err = rc.parse_dsn(user_params)
		assert(params and not err,
			"url should parse without error: " .. tostring(err))

		assert(params.master_name == "foomaster", "master_name should be foomaster")
		assert(params.role == "slave", "role should be slave")
		assert(tonumber(params.db) == 2, "db should be 2")


		local params = {
			url = "sentinels:/wrongformat",
		}

		local ok, err = rc.parse_dsn(params)
		assert(not ok and err == "could not parse DSN: nil",
			"url should fail to parse")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 9: params override dsn components
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local rc = require("resty.redis.connector")

        local user_params = {
            url = "redis://foo@127.0.0.1:6381/4",
            db = 2,
            password = "bar",
            host = "example.com",
        }

        local params, err = rc.parse_dsn(user_params)
        assert(params and not err,
            "url should parse without error: " .. tostring(err))

        assert(tonumber(params.db) == 2, "db should be 2")
        assert(params.password == "bar", "password should be bar")
        assert(params.host == "example.com", "host should be example.com")

        assert(tonumber(params.port) == 6381, "ort should still be 6381")

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 9: Integration test for parse_dsn
--- http_config eval: $::HttpConfig
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local user_params = {
            url = "redis://foo.example:$TEST_NGINX_REDIS_PORT/4",
            db = 2,
            host = "127.0.0.1",
        }

        local rc, err = require("resty.redis.connector").new(user_params)
        assert(rc and not err, "new should return positively")

        local redis, err = rc:connect()
        assert(redis and not err, "connect should return positively")
        assert(redis:set("cat", "dog") and redis:get("cat") == "dog")

        local redis, err = rc:connect({
            url = "redis://foo.example:$TEST_NGINX_REDIS_PORT/4",
            db = 2,
            host = "127.0.0.1",
        })
        assert(redis and not err, "connect should return positively")
        assert(redis:set("cat", "dog") and redis:get("cat") == "dog")


        local rc2, err = require("resty.redis.connector").new()
        local redis, err = rc2:connect({
            url = "redis://foo.example:$TEST_NGINX_REDIS_PORT/4",
            db = 2,
            host = "127.0.0.1",
        })
        assert(redis and not err, "connect should return positively")
        assert(redis:set("cat", "dog") and redis:get("cat") == "dog")

    }
}
--- request
GET /t
--- no_error_log
[error]
