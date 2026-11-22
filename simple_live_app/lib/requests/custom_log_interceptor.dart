import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';

class CustomLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra["ts"] = DateTime.now().millisecondsSinceEpoch;

    super.onRequest(options, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    var time =
        DateTime.now().millisecondsSinceEpoch - err.requestOptions.extra["ts"];
    if (!kReleaseMode) {
      Log.e('''【HTTP请求错误-${err.type}】 耗时:${time}ms
${LogSanitizer.text(err.message)}

Request Method：${err.requestOptions.method}
Response Code：${err.response?.statusCode}
Request URL：${LogSanitizer.url(err.requestOptions.uri)}
Request Query：${LogSanitizer.requestData(err.requestOptions.uri, err.requestOptions.queryParameters)}
Request Data：${LogSanitizer.requestData(err.requestOptions.uri, err.requestOptions.data)}
Request Headers：${LogSanitizer.data(err.requestOptions.headers)}
Response Headers：${LogSanitizer.data(err.response?.headers.map)}
Response Data：${LogSanitizer.data(err.response?.data)}''', err.stackTrace);
    } else {
      CoreLog.e('''[HTTP Error] [${err.type}] [Time:${time}ms]
${LogSanitizer.text(err.message)}

Request Method：${err.requestOptions.method}
Response Code：${err.response?.statusCode}
Request URL：${LogSanitizer.url(err.requestOptions.uri)}
Request Query：${LogSanitizer.requestData(err.requestOptions.uri, err.requestOptions.queryParameters)}
Request Data：${LogSanitizer.requestData(err.requestOptions.uri, err.requestOptions.data)}
Request Headers：${LogSanitizer.data(err.requestOptions.headers)}
Response Headers：${LogSanitizer.data(err.response?.headers.map)}
Response Data：${LogSanitizer.data(err.response?.data)}''', err.stackTrace);
    }

    super.onError(err, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    var time = DateTime.now().millisecondsSinceEpoch -
        response.requestOptions.extra["ts"];
    if (!kReleaseMode) {
      Log.i(
        '''【HTTP请求响应】 耗时:${time}ms
Request Method：${response.requestOptions.method}
Request Code：${response.statusCode}
Request URL：${LogSanitizer.url(response.requestOptions.uri)}
Request Query：${LogSanitizer.requestData(response.requestOptions.uri, response.requestOptions.queryParameters)}
Request Data：${LogSanitizer.requestData(response.requestOptions.uri, response.requestOptions.data)}
Request Headers：${LogSanitizer.data(response.requestOptions.headers)}
Response Headers：${LogSanitizer.data(response.headers.map)}
Response Data：${LogSanitizer.data(response.data)}''',
      );
    } else {
      CoreLog.i(
        "[HTTP Response] [time:${time}ms] [${response.statusCode}] ${LogSanitizer.url(response.requestOptions.uri)}",
      );
    }
    super.onResponse(response, handler);
  }

}
