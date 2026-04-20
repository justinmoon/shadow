use std::path::Path;

use shadow_runtime_protocol::{AppLifecycleState, AppPlatformRequest};
use shadow_ui_core::{
    app::AppId,
    control::{app_platform_request_response, MediaAction},
};

pub fn dispatch_media_action_to_app(
    runtime_dir: impl AsRef<Path>,
    app_id: AppId,
    action: MediaAction,
) -> String {
    dispatch_platform_request_to_app(
        runtime_dir,
        app_id,
        "media",
        AppPlatformRequest::Media {
            action: action.into(),
        },
    )
}

pub fn notify_lifecycle_state_to_app(
    runtime_dir: impl AsRef<Path>,
    app_id: AppId,
    state: AppLifecycleState,
) {
    let _ = dispatch_platform_request_to_app(
        runtime_dir,
        app_id,
        "lifecycle",
        AppPlatformRequest::Lifecycle { state },
    );
}

fn dispatch_platform_request_to_app(
    runtime_dir: impl AsRef<Path>,
    app_id: AppId,
    request_label: &'static str,
    request: AppPlatformRequest,
) -> String {
    match app_platform_request_response(runtime_dir.as_ref(), app_id, request) {
        Ok(response) if !response.trim().is_empty() => response,
        Ok(_) => format!(
            "ok\nhandled=0\nreason=empty-app-response\napp={}\nrequest={request_label}\n",
            app_id.as_str(),
        ),
        Err(error) => {
            let reason = match error.kind() {
                std::io::ErrorKind::NotFound
                | std::io::ErrorKind::ConnectionRefused
                | std::io::ErrorKind::AddrNotAvailable => "platform-control-unavailable",
                std::io::ErrorKind::BrokenPipe => "platform-control-write-failed",
                _ => "platform-control-read-failed",
            };
            format!(
                "ok\nhandled=0\nreason={reason}\napp={}\nrequest={request_label}\nerror={}\n",
                app_id.as_str(),
                sanitize_control_error(&error.to_string()),
            )
        }
    }
}

fn sanitize_control_error(message: &str) -> String {
    message.replace('\n', " ")
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        os::unix::net::UnixListener,
        thread,
    };

    use shadow_runtime_protocol::AppLifecycleState;
    use shadow_ui_core::{
        app::COUNTER_APP_ID,
        control::{platform_control_socket_path, MediaAction},
    };
    use tempfile::tempdir;

    use super::{dispatch_media_action_to_app, notify_lifecycle_state_to_app};

    #[test]
    fn dispatch_media_action_round_trips_through_platform_socket() {
        let runtime_dir = tempdir().expect("temp runtime dir");
        let socket_path = platform_control_socket_path(runtime_dir.path(), COUNTER_APP_ID);
        let listener = UnixListener::bind(&socket_path).expect("bind platform socket");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept platform request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("read platform request");
            assert_eq!(request, "media play-pause\n");
            stream
                .write_all(b"ok\nhandled=1\nsource=test\n")
                .expect("write platform response");
        });

        let response = dispatch_media_action_to_app(
            runtime_dir.path(),
            COUNTER_APP_ID,
            MediaAction::PlayPause,
        );
        assert_eq!(response, "ok\nhandled=1\nsource=test\n");
        server.join().expect("join platform server");
    }

    #[test]
    fn dispatch_media_action_reports_missing_platform_socket() {
        let runtime_dir = tempdir().expect("temp runtime dir");

        let response = dispatch_media_action_to_app(
            runtime_dir.path(),
            COUNTER_APP_ID,
            MediaAction::PlayPause,
        );

        assert!(response.contains("ok\nhandled=0\n"));
        assert!(response.contains("reason=platform-control-unavailable\n"));
        assert!(response.contains("app=counter\n"));
        assert!(response.contains("request=media\n"));
    }

    #[test]
    fn notify_lifecycle_state_sends_background_request() {
        let runtime_dir = tempdir().expect("temp runtime dir");
        let socket_path = platform_control_socket_path(runtime_dir.path(), COUNTER_APP_ID);
        let listener = UnixListener::bind(&socket_path).expect("bind platform socket");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept platform request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("read platform request");
            assert_eq!(request, "lifecycle background\n");
        });

        notify_lifecycle_state_to_app(
            runtime_dir.path(),
            COUNTER_APP_ID,
            AppLifecycleState::Background,
        );

        server.join().expect("join platform server");
    }

    #[test]
    fn dispatch_media_action_reports_empty_platform_response() {
        let runtime_dir = tempdir().expect("temp runtime dir");
        let socket_path = platform_control_socket_path(runtime_dir.path(), COUNTER_APP_ID);
        let listener = UnixListener::bind(&socket_path).expect("bind platform socket");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept platform request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("read platform request");
            assert_eq!(request, "media play-pause\n");
        });

        let response = dispatch_media_action_to_app(
            runtime_dir.path(),
            COUNTER_APP_ID,
            MediaAction::PlayPause,
        );

        assert!(response.contains("ok\nhandled=0\n"));
        assert!(response.contains("reason=empty-app-response\n"));
        assert!(response.contains("app=counter\n"));
        assert!(response.contains("request=media\n"));
        server.join().expect("join platform server");
    }
}
