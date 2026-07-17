/// Error codes for kernel operations FFI.
/// 0 = success, negative = error.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ErrorCode {
    Ok = 0,
    NftablesFailed = -3,
    NetlinkFailed = -4,
    InvalidParam = -5,
    IoError = -6,
    PermissionDenied = -7,
    NotInitialized = -8,
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ok => write!(f, "OK"),
            Self::NftablesFailed => write!(f, "nftables operation failed"),
            Self::NetlinkFailed => write!(f, "Netlink operation failed"),
            Self::InvalidParam => write!(f, "Invalid parameter"),
            Self::IoError => write!(f, "I/O error"),
            Self::PermissionDenied => write!(f, "Permission denied"),
            Self::NotInitialized => write!(f, "Context not initialized"),
        }
    }
}
