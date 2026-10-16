"""Finalize only explicitly registered acceptance resources, under their own account."""


class OwnedResources:
    def __init__(self, request, credential, after_membership=None):
        self.request = request
        self.credential = credential
        self.resources = {}
        self.after_membership = after_membership

    def __enter__(self):
        return self.call

    def call(self, path, body=None, method='GET', **kwargs):
        credential = kwargs.get('credential', self.credential)
        key = (path, credential)
        if method == 'DELETE' and kwargs.get('expected', 200) == 200 and self.resources.get(key):
            self.request(path + '/members', dict(userIds=[]), 'PUT', credential=credential, expected=(200, 404))
        value = self.request(path, body, method, **kwargs)
        if method == 'POST' and path in ('/cohorts', '/metric-definitions') and kwargs.get('expected', 200) == 200:
            self.resources[(path + '/' + value['id'], credential)] = path == '/cohorts' and body['kind'] == 'static'
        elif method == 'DELETE' and kwargs.get('expected', 200) == 200:
            self.resources.pop(key, None)
        if method == 'PUT' and path.endswith('/members') and body.get('userIds') and self.after_membership:
            self.after_membership(path)
        return value

    def __exit__(self, kind, error, traceback):
        failures = []
        # Saved metrics may depend on cohorts: delete them before membership and
        # cohort definitions. Keep attempting every recorded resource on failure.
        for (path, credential), static in sorted(self.resources.items(), key=lambda item: not item[0][0].startswith('/metric-definitions/')):
            try:
                if static:
                    self.request(path + '/members', dict(userIds=[]), 'PUT', credential=credential, expected=(200, 404))
                self.request(path, method='DELETE', credential=credential, expected=(200, 404))
            except Exception:
                failures.append(path)
        if failures:
            message = 'acceptance cleanup failed for owned resources: ' + ', '.join(failures)
            if error is not None:
                error.add_note(message)
            else:
                raise AssertionError(message)
        return False
