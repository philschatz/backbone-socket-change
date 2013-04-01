# What is this?

This example shows how to synchronize Backbone Models on the client browser with Backbone Models on a nodejs webserver.

This means a `model.set('hello', 'world')` in the browser will cause a `model.set(...)` on the server and a `model.set(...)` on each client listening to the same model.

When a `model.sync({success: ...})` is called on the browser, the `sync` method is instead called on the server but when the `sync` completes on the server the `success/error` callbacks on the browser model are called.
