// Generated by IcedCoffeeScript 1.3.1a
var parallelSearch;

parallelSearch = function(keywords, cb) {
  var cb_generator, i, k, n_out, results, _i, _len, _results;
  results = [];
  n_out = 0;
  cb_generator = function(i) {
    n_out++;
    return function(json) {
      results[i] = json;
      if (n_out-- === 0) return cb(results);
    };
  };
  _results = [];
  for (i = _i = 0, _len = keywords.length; _i < _len; i = ++_i) {
    k = keywords[i];
    _results.push(search(k, cb_generator(i)));
  }
  return _results;
};