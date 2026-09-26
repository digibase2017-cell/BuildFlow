# Build Flow — bàn giao trường Lead/Project (26/09/2026)

Đã triển khai migration 011, không sửa nội dung migration 001–010. SQL nguồn là `source_migrations/011_lead_fields.sql`; bản Supabase được tạo bằng `npm run migrations:sync`.

| Yêu cầu | Nơi lưu | Hành vi |
| --- | --- | --- |
| Source 2, Source 3 | `leads.source_2`, `leads.source_3` | Văn bản chi tiết chiến dịch/bài và ID. `leads.source` hiện hữu là option Nguồn. |
| Loại thực hiện | `leads.execution_types`, `projects.execution_types` | Mảng nhiều lựa chọn. Project sao chép ban đầu từ Lead rồi độc lập. Không thay cờ module. |
| Loại công trình | `leads.building_type`, `projects.building_type` | Một lựa chọn; Project sao chép ban đầu rồi độc lập. Đã nối cột bảng Project và XLSX. |
| Ngân sách | `leads.budget`, `project_financials.budget` | Một giá trị tại mỗi nơi, nhập tay và độc lập; không tự tổng hợp chi phí. |
| Trạng thái Sale | `leads.status` hiện hữu | Giữ sáu trạng thái, chuyển lại Thành công/Thất bại được. |
| Lý do thất bại | `leads.failure_reason` | Bắt buộc khi `status='Thất bại'`; được chọn từ option của cùng công ty. |

`lead_options` chứa option riêng cho từng công ty. Bốn loại option là source, execution_type, building_type, failure_reason. Nút ＋ thêm/kích hoạt lại option; nút × chuyển `is_active=false`. Giá trị cũ là snapshot văn bản trên Lead/Project nên vẫn hiển thị sau khi option ẩn. Giá trị mới và lựa chọn thay đổi được kiểm tra với danh mục đang active theo company_id. Source 2/3 không phải dropdown vì là nội dung/ID chi tiết riêng từng chiến dịch.

RLS giữ nguyên phạm vi Lead/Project. Bảng option chỉ cho SELECT trong cùng công ty; client không được DELETE/UPDATE trực tiếp. RPC thêm/ẩn option đòi tài khoản active, thuê bao cho ghi và `lead.create`, `lead.edit` hoặc `project.edit` cho loại dùng trên Project. RPC `my_capabilities` trả quyền hiệu lực của chính user để hiện nút đúng quyền, bao gồm user allow/deny. RPC ngân sách Project chỉ đọc/ghi `budget`: Sales/Marketing có `lead.view/edit` hiệu lực và nằm trong phạm vi Lead nguồn được xem/sửa ngân sách của Project liên kết ngay tại Lead; người có `financial.edit` và phạm vi Project cũng được sửa. `contract_value` và các thông tin tài chính khác vẫn giữ quyền tài chính riêng.

Kiểm thử đã chạy: `npm ci`, `npm run check`, `npm run local:start`, `npm run db:reset`, `npm run db:lint`, `npm run db:test` với 198/198 pgTAP sau sửa quyền DELETE; `npm run app:check`, `npm run app:test` 6/6. UI Lead đã kiểm thử bằng Edge headless với JWT Owner: tạo option, lý do bắt buộc, ẩn option giữ lịch sử, chọn nhiều loại thực hiện, sao chép sang Project và nhập hai ngân sách. Chưa mở XLSX bằng Excel desktop; đã kiểm tra bằng openpyxl ở lượt trước. Chưa stress test hoặc kiểm tra mọi lịch concurrency của danh mục option.

Lưu ý nghiệp vụ: lý do thất bại cũ vẫn nằm trên Lead sau khi đổi lại Thành công để không mất ngữ cảnh; UI chỉ hiện bộ chọn khi chọn Thất bại. Nếu muốn xóa lý do khi đổi trạng thái, cần chốt thêm trước khi thay đổi. Các option mặc định cho loại thực hiện và công trình được tạo cho company mới; lý do thất bại không seed sẵn.

Bước tiếp theo: thử với dữ liệu nghiệp vụ thật trên Supabase Local, chốt thêm danh mục option mặc định nếu cần và kiểm thử sâu quyền Role/user override cùng thao tác đồng thời. Không triển khai cloud trong lượt này.

Ghi chú: các kết quả kiểm thử nêu trên là của phiên bản trước khi đổi từ hai ngân sách thành một; xem kết quả kiểm thử mới trong báo cáo cuối của lượt sửa ngân sách.

Sau khi đổi ngân sách: `npm ci`, `npm run check`, `npm run local:start`, `npm run db:reset`, `npm run db:lint`, `npm run db:test` (203/203), `npm run app:check`, `npm run app:test` (6/6) và Edge headless 1366×768 cho form Lead/Project đều đạt. pgTAP kiểm tra Sales/Marketing được nhập ngân sách Project qua Lead nguồn nhưng Marketing vẫn không xem được hàng `project_financials`. Database local được reset lại sau kiểm thử trình duyệt. Chưa kiểm tra giao diện bằng tài khoản Marketing trong browser hoặc triển khai cloud.

Bộ hồi quy HTTP/concurrency cũ cũng đạt 1058/1058 trên migration 011 trước lần siết cuối quyền đọc option; sau thay đổi này, 198/198 pgTAP và kiểm thử trình duyệt Project 51 dòng đạt. Không chạy lại toàn bộ 1058 ca chỉ cho thay đổi quyền đọc option vì ca mới đã kiểm tra đúng phạm vi Lead/Project.
