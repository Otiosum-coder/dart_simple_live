import 'package:dio/dio.dart';

import 'core_log.dart';
import 'log_sanitizer.dart';

class CustomInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra["ts"] = DateTime.now().millisecondsSinceEpoch;
    if (CoreLog.requestLogType == RequestLogType.all) {
      CoreLog.i(
        '''[HTTP Request] [${options.method}]
Request URL：${LogSanitizer.url(options.uri)}
Request Query：${LogSanitizer.requestData(options.uri, options.queryParameters)}
Request Data：${LogSanitizer.requestData(options.uri, options.data)}
Request Headers：${LogSanitizer.data(options.headers)}''',
      );
    } else if (CoreLog.requestLogType == RequestLogType.short) {
      CoreLog.i("[HTTP Request] [${options.method}] ${LogSanitizer.url(options.uri)}");
    }

    super.onRequest(options, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    var time =
        DateTime.now().millisecondsSinceEpoch - err.requestOptions.extra["ts"];
    if (CoreLog.requestLogType == RequestLogType.all) {
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
    } else {
      CoreLog.e(
        "[HTTP Error] [${err.type}] [Time:${time}ms]\n[${err.response?.statusCode}] ${LogSanitizer.url(err.requestOptions.uri)}",
        err.stackTrace,
      );
    }

    super.onError(err, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    var time = DateTime.now().millisecondsSinceEpoch -
        response.requestOptions.extra["ts"];
    if (CoreLog.requestLogType == RequestLogType.all) {
      CoreLog.i(
        '''[HTTP Response] [time:${time}ms]
Request Method：${response.requestOptions.method}
Request Code：${response.statusCode}
Request URL：${LogSanitizer.url(response.requestOptions.uri)}
Request Query：${LogSanitizer.requestData(response.requestOptions.uri, response.requestOptions.queryParameters)}
Request Data：${LogSanitizer.requestData(response.requestOptions.uri, response.requestOptions.data)}
Request Headers：${LogSanitizer.data(response.requestOptions.headers)}
Response Headers：${LogSanitizer.data(response.headers.map)}
Response Data：${LogSanitizer.data(response.data)}''',
      );
    } else if (CoreLog.requestLogType == RequestLogType.short) {
      CoreLog.i(
        "[HTTP Response] [time:${time}ms] [${response.statusCode}] ${LogSanitizer.url(response.requestOptions.uri)}",
      );
    }
    super.onResponse(response, handler);
  }
}
